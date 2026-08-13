-- @lib: llm_extract
-- @category: udf
-- @desc: 把「LLM 结构化信息提取」封装成 SQL 函数——调任意 OpenAI 兼容端点（默认本地 vLLM），
--        schema + few-shot 约束输出 JSON。合同/公告/评论/简历的批量字段提取、
--        复杂语言识别、情感/实体抽取一把梭。本质 = 一行 SQL 内嵌 LLM 调用。
-- @source: original（duckdb-luajit 系列）
-- @requires: curl CLI（io.popen 调系统 curl：Windows 10+ 自带 curl.exe）
-- ⚠️ 需普通模式（非 trusted）：io.popen / os 用于发起 HTTP 请求
--
-- Usage (duckdb-luajit):
--   install:     SELECT * FROM luajit_module(mode:='install', sql_name:='llm_extract');
--   quick_compile:
--     SELECT * FROM luajit_module(mode:='quick_compile', sql_name:='llm_extract',
--       source:=(SELECT content FROM read_text('/path/to/llm_extract.lua')));
--   结构化提取（返回 schema 约束的 JSON 字符串，再交给 DuckDB json_extract 展开）：
--     SELECT luajit_s('llm_extract', {'op':'extract',
--       'text': comment,
--       'schema': '{"type":"object","properties":{"company":{"type":"string"},"amount":{"type":"number"}},"required":["company"]}',
--       'examples': '{"input":"甲方智云科技支付50000元","output":"{\\"company\\":\\"智云科技\\",\\"amount\\":50000}"}',
--       'endpoint': 'http://10.10.10.115:8011', 'model': 'qwen3.6-35b-a3b'}) FROM comments;
--   通用对话（调试/兜底）：SELECT luajit_s('llm_extract', {'op':'chat', 'text':'你好'});
--
-- 设计要点：
--   * 只做「调 LLM + 回传 content」，JSON 展开永远交给 DuckDB 原生 json_extract；
--   * reasoning 模型（qwen3）默认 enable_thinking=false 关思考（提取任务要快），
--     需要深度推理时 p.thinking=true 开启；
--   * 批量场景 = DuckDB 逐行调标量 UDF（每行一次 LLM 调用，本地 vLLM 高并发可接受）；
--   * 端点/模型可配（p.endpoint / p.model / 环境变量 LLM_EXTRACT_ENDPOINT），
--     不绑定任何云厂商，本地模型零成本。

local M = {}

-- ============ JSON 工具（最小实现，避免依赖顺序） ============
-- 字符串 → JSON 字符串字面量（转义控制字符/引号/反斜杠）
local function json_escape(s)
  return (s:gsub('[%c\\"]', function(c)
    if c == '"' then return '\\"' end
    if c == '\\' then return '\\\\' end
    if c == '\n' then return '\\n' end
    if c == '\r' then return '\\r' end
    if c == '\t' then return '\\t' end
    return string.format('\\u%04x', c:byte())
  end))
end

-- 码点 → UTF-8 字节串
local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096),
      0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
  return string.char(0xF0 + math.floor(cp / 262144),
    0x80 + math.floor(cp / 4096) % 64, 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

-- 从 chat.completion 响应中提取 message.content 的字符串值（处理 \uXXXX 转义含代理对）
-- 返回 content 原文（JSON 文本）或 nil, errmsg
local function extract_content(resp)
  local start = resp:find('"content"%s*:%s*"')
  if not start then return nil, 'no "content" field in response' end
  -- 跳过 "content": " 定位到值起点
  local _, vstart = resp:find('"content"%s*:%s*"', start)
  if not vstart then return nil, 'malformed content field' end
  local out = {}
  local i = vstart + 1
  local n = #resp
  while i <= n do
    local c = resp:sub(i, i)
    if c == '\\' then
      local nxt = resp:sub(i + 1, i + 1)
      local consumed = 2 -- 每个转义至少消费 \<c> 两个字节
      if nxt == 'n' then out[#out + 1] = '\n'
      elseif nxt == 't' then out[#out + 1] = '\t'
      elseif nxt == 'r' then out[#out + 1] = '\r'
      elseif nxt == '"' then out[#out + 1] = '"'
      elseif nxt == '\\' then out[#out + 1] = '\\'
      elseif nxt == '/' then out[#out + 1] = '/'
      elseif nxt == 'u' then
        local hex = resp:sub(i + 2, i + 5)
        local cp = tonumber(hex, 16) or 0
        if cp >= 0xD800 and cp <= 0xDBFF then
          -- 高位代理：读取低位代理 \uXXXX\uYYYY
          local hex2 = resp:sub(i + 8, i + 11)
          local cp2 = tonumber(hex2, 16) or 0
          out[#out + 1] = utf8_char(0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00))
          consumed = 12
        else
          out[#out + 1] = utf8_char(cp)
          consumed = 6
        end
      else
        out[#out + 1] = nxt -- 未知转义：原样
      end
      i = i + consumed
    elseif c == '"' then
      return table.concat(out)
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out) -- 未闭合（理论不该发生）
end

-- ============ 请求构造 ============
local function build_payload(p)
  local sys = p.system or '你是结构化信息提取器。严格按给定 schema 输出 JSON，只输出 JSON 本身，'
    .. '不要任何解释、markdown 代码块或额外文字。'
  local user = ''
  if p.schema and p.schema ~= '' then
    user = 'schema: ' .. p.schema
  end
  if p.examples and p.examples ~= '' then
    user = user .. '\n\nexamples:\n' .. p.examples
  end
  user = user .. '\n\ntext: ' .. (p.text or '')
  local payload = {
    model = p.model or 'qwen3.6-35b-a3b',
    temperature = p.temperature or 0,
    max_tokens = p.max_tokens or 1024,
    stream = false,
    chat_template_kwargs = { enable_thinking = p.thinking == true },
    messages = {
      { role = 'system', content = sys },
      { role = 'user', content = user },
    },
  }
  local body = '{"model":"' .. json_escape(payload.model) .. '"'
    .. ',"temperature":' .. tostring(payload.temperature)
    .. ',"max_tokens":' .. tostring(payload.max_tokens)
    .. ',"stream":false,"chat_template_kwargs":{"enable_thinking":'
    .. (payload.chat_template_kwargs.enable_thinking and 'true' or 'false')
    .. '},"messages":[{"role":"system","content":"' .. json_escape(sys)
    .. '"},{"role":"user","content":"' .. json_escape(user) .. '"}]}'
  return body
end

-- ============ HTTP 调用（curl CLI，跨平台） ============
local function post_chat(endpoint, body, timeout)
  local tmp = os.tmpname()
  local f = io.open(tmp, 'wb')
  if not f then return nil, 'cannot write temp file' end
  f:write(body)
  f:close()
  local cmd = string.format(
    "curl -s --max-time %d -X POST '%s/v1/chat/completions' -H 'Content-Type: application/json' --data-binary @'%s'",
    timeout or 120, endpoint, tmp)
  local pipe = io.popen(cmd)
  if not pipe then os.remove(tmp) return nil, 'io.popen failed (needs normal mode)' end
  local resp = pipe:read('*a')
  pipe:close()
  os.remove(tmp)
  if not resp or resp == '' then
    return nil, 'empty response from ' .. endpoint .. ' (endpoint reachable?)'
  end
  return resp
end

-- ============ 主逻辑 ============
-- p.endpoint 优先级：p.endpoint > 环境变量 LLM_EXTRACT_ENDPOINT > 默认本地 vLLM
local function resolve_endpoint(p)
  if p.endpoint and p.endpoint ~= '' then return p.endpoint end
  local env = os.getenv and os.getenv('LLM_EXTRACT_ENDPOINT')
  if env and env ~= '' then return env end
  return 'http://10.10.10.115:8011'
end

function M.extract(p)
  local endpoint = resolve_endpoint(p)
  local body = build_payload(p)
  local resp, err = post_chat(endpoint, body, p.timeout)
  if not resp then return nil, err end
  -- 顶层错误（vLLM 返回 {"error":...}）
  if resp:find('"error"') then
    local msg = resp:match('"message"%s*:%s*"([^"]*)')
    return nil, 'LLM error: ' .. tostring(msg or resp:sub(1, 200))
  end
  local content, cerr = extract_content(resp)
  if not content then
    return nil, 'parse error: ' .. tostring(cerr) .. ' | raw: ' .. resp:sub(1, 300)
  end
  if content == '' then
    -- reasoning 模型思考被截断等情况：提示重试或开 thinking
    return nil, 'empty content (reasoning model? try thinking=true or raise max_tokens)'
  end
  return content
end

-- ============ UDF 入口 ============
return function(p)
  if type(p) ~= 'table' then return 'error: llm_extract expects a struct argument' end
  local op = p.op or 'extract'
  local r, err
  if op == 'chat' then
    -- 通用对话：直接回 content
    local body = build_payload({ text = p.text, model = p.model, temperature = p.temperature,
      max_tokens = p.max_tokens, thinking = p.thinking, system = p.system, endpoint = p.endpoint })
    local resp, perr = post_chat(resolve_endpoint(p), body, p.timeout)
    if not resp then return 'error: ' .. tostring(perr) end
    r, err = extract_content(resp)
  else
    r, err = M.extract(p)
  end
  if not r then return 'error: ' .. tostring(err) end
  return r
end
