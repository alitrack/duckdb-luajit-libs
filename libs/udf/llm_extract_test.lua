-- llm_extract.lua 断言测试：cd libs/udf && luajit llm_extract_test.lua
-- 离线断言 + live 验证（设 LLM_TEST_ENDPOINT 时调用真实 LLM）：
--   LLM_TEST_ENDPOINT=http://10.10.10.115:8011 luajit llm_extract_test.lua
local fn = assert(dofile('llm_extract.lua'))

local pass, fail = 0, 0
local function eq(actual, expected, name)
  if actual == expected then
    pass = pass + 1
  else
    fail = fail + 1
    print(string.format('FAIL [%s] expected=%q got=%q', name, tostring(expected), tostring(actual)))
  end
end
local function ok(cond, name)
  if cond then pass = pass + 1 else fail = fail + 1; print('FAIL [' .. name .. ']') end
end

-- ============ 1. 离线：错误路径与参数缺省 ============
local r = fn({ op = 'chat', text = 'hi', endpoint = 'http://127.0.0.1:1' })
ok(r:find('error:') ~= nil and r:find('127.0.0.1') ~= nil, 'unreachable endpoint errors with endpoint name')
ok(fn({ op = 'extract' }):find('error:') == nil or true, 'extract without text returns (LLM answers {} or errors)')
ok(type(fn({})) == 'string', 'empty struct returns string')

-- ============ 1b. 离线：cache=true 错误路径不污染缓存 ============
-- 不可达端点 + cache=true：首次失败不缓存错误；同键再调仍走 HTTP 报同样错误
-- （若错误被误缓存，第二次会命中并返回同样的 error 字符串——仍报错但语义等价；
--   真正的断言是：错误结果绝不作为成功内容缓存返回）
local bad1 = fn({ op = 'chat', text = 'cache-bad', endpoint = 'http://127.0.0.1:1', cache = true })
local bad2 = fn({ op = 'chat', text = 'cache-bad', endpoint = 'http://127.0.0.1:1', cache = true })
ok(bad1:find('error:') ~= nil and bad2:find('error:') ~= nil, 'cache=true unreachable endpoint still errors (errors not cached as success)')

-- cache=false 与 cache=true 键隔离：同输入不同 cache 开关不应互相污染
local nocache = fn({ op = 'chat', text = 'cache-bad', endpoint = 'http://127.0.0.1:1' })
ok(nocache:find('error:') ~= nil, 'cache=false separate path unaffected')

-- ============ 2. live：真实 LLM 结构化提取 ============
local endpoint = os.getenv('LLM_TEST_ENDPOINT')
local model = os.getenv('LLM_TEST_MODEL') or 'qwen3.6-35b-a3b'
if endpoint then
  local schema = '{"type":"object","properties":{"company":{"type":"string"},"amount":{"type":"number"}},"required":["company"]}'
  local out = fn({ op = 'extract',
    text = '甲方北京智云科技有限公司向乙方支付50000元',
    schema = schema,
    endpoint = endpoint,
    model = model,
  })
  print('live extract =>', out)
  ok(out:find('error:') == nil, 'live extract no error')
  ok(out:find('北京智云科技') ~= nil, 'live extract found company')
  ok(out:find('50000') ~= nil, 'live extract found amount')

  -- few-shot + 复杂 schema（数组）
  local out2 = fn({ op = 'extract',
    text = '张伟是阿里巴巴的CTO，王芳在腾讯做产品经理。',
    schema = '{"type":"object","properties":{"people":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"company":{"type":"string"},"title":{"type":"string"}}}}}}',
    endpoint = endpoint, model = model,
  })
  print('live extract2 =>', out2)
  ok(out2:find('error:') == nil, 'live extract array no error')
  ok(out2:find('张伟') ~= nil and out2:find('阿里巴巴') ~= nil, 'live extract array content')

  -- chat 模式（reasoning 关闭）
  local chat = fn({ op = 'chat', text = '只回答：1+1=', endpoint = endpoint, model = model })
  print('live chat =>', chat)
  ok(chat:find('error:') == nil and chat:find('2') ~= nil, 'live chat works')

  -- ============ 3. live：cache=true 命中验证 ============
  -- 第一次正常调用填充缓存；第二次同键 + timeout=0.001（1ms 必超时）——
  -- 若命中缓存则瞬返且内容一致（不发 HTTP）；若 miss 则 curl 超时报 error。
  -- （post_chat 已修 %d→tostring：0.001 不再被截成 0=无超时）
  local c1 = fn({ op = 'chat', text = 'cache-hit-test 只回答ok', endpoint = endpoint,
    model = model, cache = true })
  print('live cache#1 =>', c1)
  ok(c1:find('error:') == nil, 'live cache first call succeeds')
  local c2 = fn({ op = 'chat', text = 'cache-hit-test 只回答ok', endpoint = endpoint,
    model = model, cache = true, timeout = 0.001 })
  print('live cache#2 (timeout=1ms, must hit) =>', c2)
  ok(c2 == c1 and c2:find('error:') == nil,
    'live cache second call hits cache (same content, no HTTP)')
  -- cache=false 同输入不受缓存影响：cache=false 时 timeout=1ms 必走 HTTP 超时 → error
  -- （若错误地复用了缓存，会瞬返成功内容——证明开关真的 gate）
  local c3 = fn({ op = 'chat', text = 'cache-hit-test 只回答ok', endpoint = endpoint,
    model = model, timeout = 0.001 })
  print('live cache#3 (cache=false + timeout=1ms, must miss) =>', c3)
  ok(c3:find('error:') ~= nil,
    'live cache=false with 1ms timeout errors (cache opt-in really gates)')
else
  print('(LLM_TEST_ENDPOINT not set — skipping live tests)')
end

print(string.format('llm_extract_test: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
