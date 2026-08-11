/* vba_bridge2.c — 生产版：QuickJS + yiminghe/vba 引擎持久 runtime
 * 生命周期：vba_init 一次（加载 bundle + 建 Context）→ vba_load 可多次
 *           → vba_call 任意次（同一 Context，VBA 全局状态保持）→ 进程退出
 * 线程安全：pthread mutex 串行化（duckdb 可能多线程调 UDF）
 * 编译：gcc -shared -fPIC -O2 -pthread -I/tmp/quickjs -o /tmp/vba_bridge2.so \
 *         vba_bridge2.c -L/tmp/quickjs -lquickjs -lm
 * Lua cdef:
 *   int vba_init(const char* bundle_path);
 *   int vba_load(const char* code);
 *   const char* vba_call(const char* subname, const char* args_json);
 *   const char* vba_last_error(void);
 *   void vba_free(const char* s);
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

static JSRuntime *g_rt = NULL;
static JSContext *g_ctx = NULL;
static int g_ready = 0;
static char g_err[1024];
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static char *read_file(const char *path, long *out_len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = malloc(n + 1);
  if (!buf) { fclose(f); return NULL; }
  if (fread(buf, 1, n, f) != (size_t)n) { free(buf); fclose(f); return NULL; }
  buf[n] = 0;
  fclose(f);
  *out_len = n;
  return buf;
}

static void set_err(const char *msg) { snprintf(g_err, sizeof(g_err), "%s", msg); }

static void dump_exception(JSContext *ctx) {
  JSValue ex = JS_GetException(ctx);
  const char *s = JS_ToCString(ctx, ex);
  set_err(s ? s : "unknown JS error");
  JS_FreeCString(ctx, s);
  JS_FreeValue(ctx, ex);
}

static int flush_jobs(JSRuntime *rt) {
  JSContext *ctx1;
  int cnt = 0;
  for (;;) {
    int err = JS_ExecutePendingJob(rt, &ctx1);
    if (err == 0) break;
    if (err < 0) { dump_exception(ctx1); return -1; }
    if (++cnt > 200000) { set_err("job queue runaway"); return -1; }
  }
  return 0;
}

/* 调用 JS 函数（0 参或 1 参），推进微任务；返回 JS 值（调用者负责 FreeValue） */
static JSValue js_invoke(const char *fn_name, const char *arg) {
  JSValue g = JS_GetGlobalObject(g_ctx);
  JSValue fn = JS_GetPropertyStr(g_ctx, g, fn_name);
  JSValue r;
  if (arg) {
    JSValue a = JS_NewString(g_ctx, arg);
    r = JS_Call(g_ctx, fn, JS_UNDEFINED, 1, (JSValue[]){ a });
    JS_FreeValue(g_ctx, a);
  } else {
    r = JS_Call(g_ctx, fn, JS_UNDEFINED, 0, NULL);
  }
  JS_FreeValue(g_ctx, fn);
  JS_FreeValue(g_ctx, g);
  return r;
}

int vba_init(const char *bundle_path) {
  pthread_mutex_lock(&g_mu);
  if (g_ready) { pthread_mutex_unlock(&g_mu); return 0; }
  g_err[0] = 0;
  g_rt = JS_NewRuntime();
  g_ctx = JS_NewContext(g_rt);

  long blen;
  char *bundle = read_file(bundle_path, &blen);
  if (!bundle) { set_err("bundle read failed"); goto fail; }
  char *tail = strstr(bundle, "export {");
  if (!tail) { set_err("no export line in bundle"); free(bundle); goto fail; }
  strcpy(tail, "globalThis.__vba = { Context: Context, VBArguments: VBArguments, parser: vbaParser };\n");

  JSValue r = JS_Eval(g_ctx, bundle, strlen(bundle), "vba.js", JS_EVAL_TYPE_GLOBAL);
  free(bundle);
  if (JS_IsException(r)) { dump_exception(g_ctx); goto fail; }
  JS_FreeValue(g_ctx, r);

  /* driver：持久 Context + 宿主绑定 + load/call */
  const char *driver =
    "if (!globalThis.console) globalThis.console = { log: function(){}, error: function(){}, warn: function(){}, info: function(){} };\n"
    "globalThis.__logs = [];\n"
    "globalThis.__result = 'null';\n"
    "globalThis.__vbaInit = async function() {\n"
    "  const Ctx = globalThis.__vba.Context;\n"
    "  const ctx = new Ctx();\n"
    "  globalThis.__vbaCtx = ctx;\n"
    "  ctx.registerSubBinding({ name: 'debug.print', argumentsInfo: [{ name: 'msg' }],\n"
    "    async value(args) { globalThis.__logs.push(String((await args.getValue('msg'))?.value)); } });\n"
    "  ctx.registerSubBinding({ name: 'HOST_RMB', argumentsInfo: [{ name: 'n' }],\n"
    "    async value(args) { return Ctx.createString('RMB(' + (await args.getValue('n')).value + ')'); } });\n"
    "  return 'ok';\n"
    "};\n"
    "globalThis.__vbaLoad = async function(code) {\n"
    "  await globalThis.__vbaCtx.load(code);\n"
    "  return 'ok';\n"
    "};\n"
    "globalThis.__vbaCall = async function(jsonArgs) {\n"
    "  try {\n"
    "    const Ctx = globalThis.__vba.Context;\n"
    "    const ctx = globalThis.__vbaCtx;\n"
    "    globalThis.__logs = [];\n"
    "    const arr = JSON.parse(jsonArgs || '[]');\n"
    "    const args = new globalThis.__vba.VBArguments(ctx, arr.map(v => {\n"
    "      if (typeof v === 'number') return Ctx.createDouble(v);\n"
    "      if (typeof v === 'boolean') return Ctx.createBoolean(v);\n"
    "      return Ctx.createString(String(v));\n"
    "    }));\n"
    "    const r = await ctx.callSub(globalThis.__vbaSub, { args });\n"
    "    globalThis.__result = JSON.stringify({\n"
    "      logs: globalThis.__logs,\n"
    "      ret: r ? (typeof r.value === 'number' ? r.value : String(r.value)) : null\n"
    "    });\n"
    "  } catch (e) {\n"
    "    globalThis.__result = JSON.stringify({ err: String((e && e.message) || e) });\n"
    "  }\n"
    "};\n"
    "globalThis.__vbaSetSub = function(n) { globalThis.__vbaSub = n; return 'ok'; };\n";
  r = JS_Eval(g_ctx, driver, strlen(driver), "driver.js", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(r)) { dump_exception(g_ctx); goto fail; }
  JS_FreeValue(g_ctx, r);

  r = js_invoke("__vbaInit", NULL);
  if (JS_IsException(r)) { dump_exception(g_ctx); goto fail; }
  JS_FreeValue(g_ctx, r);
  if (flush_jobs(g_rt) < 0) goto fail;

  g_ready = 1;
  pthread_mutex_unlock(&g_mu);
  return 0;
fail:
  g_ready = 0;
  if (g_ctx) { JS_FreeContext(g_ctx); g_ctx = NULL; }
  if (g_rt) { JS_FreeRuntime(g_rt); g_rt = NULL; }
  pthread_mutex_unlock(&g_mu);
  return -1;
}

int vba_load(const char *code) {
  pthread_mutex_lock(&g_mu);
  if (!g_ready) { set_err("not initialized"); pthread_mutex_unlock(&g_mu); return -1; }
  g_err[0] = 0;
  JSValue r = js_invoke("__vbaLoad", code);
  if (JS_IsException(r)) { dump_exception(g_ctx); JS_FreeValue(g_ctx, r); pthread_mutex_unlock(&g_mu); return -1; }
  JS_FreeValue(g_ctx, r);
  if (flush_jobs(g_rt) < 0) { pthread_mutex_unlock(&g_mu); return -1; }
  pthread_mutex_unlock(&g_mu);
  return 0;
}

/* 返回 malloc'd JSON；用后 vba_free */
const char *vba_call(const char *subname, const char *args_json) {
  pthread_mutex_lock(&g_mu);
  if (!g_ready) { set_err("not initialized"); pthread_mutex_unlock(&g_mu); return strdup("{\"err\":\"not initialized\"}"); }
  g_err[0] = 0;
  JSValue g = JS_GetGlobalObject(g_ctx);
  JSValue setr = JS_Call(g_ctx, JS_GetPropertyStr(g_ctx, g, "__vbaSetSub"), JS_UNDEFINED, 1, (JSValue[]){ JS_NewString(g_ctx, subname) });
  JS_FreeValue(g_ctx, setr);
  JS_FreeValue(g_ctx, g);
  JSValue r = js_invoke("__vbaCall", args_json ? args_json : "[]");
  if (JS_IsException(r)) { dump_exception(g_ctx); JS_FreeValue(g_ctx, r); pthread_mutex_unlock(&g_mu); return strdup("{\"err\":\"JS exception\"}"); }
  JS_FreeValue(g_ctx, r);
  if (flush_jobs(g_rt) < 0) { pthread_mutex_unlock(&g_mu); return strdup("{\"err\":\"job failure\"}"); }

  g = JS_GetGlobalObject(g_ctx);
  JSValue res = JS_GetPropertyStr(g_ctx, g, "__result");
  JS_FreeValue(g_ctx, g);
  const char *tmp = JS_ToCString(g_ctx, res);
  char *out = strdup(tmp ? tmp : "null");
  JS_FreeCString(g_ctx, tmp);
  JS_FreeValue(g_ctx, res);
  pthread_mutex_unlock(&g_mu);
  return out;
}

const char *vba_last_error(void) {
  return g_err;
}

void vba_free(const char *s) { free((void *)s); }
