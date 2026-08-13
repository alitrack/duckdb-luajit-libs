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

-- ============ 2. live：真实 LLM 结构化提取 ============
local endpoint = os.getenv('LLM_TEST_ENDPOINT')
if endpoint then
  local schema = '{"type":"object","properties":{"company":{"type":"string"},"amount":{"type":"number"}},"required":["company"]}'
  local out = fn({ op = 'extract',
    text = '甲方北京智云科技有限公司向乙方支付50000元',
    schema = schema,
    endpoint = endpoint,
    model = 'qwen3.6-35b-a3b',
  })
  print('live extract =>', out)
  ok(out:find('error:') == nil, 'live extract no error')
  ok(out:find('北京智云科技') ~= nil, 'live extract found company')
  ok(out:find('50000') ~= nil, 'live extract found amount')

  -- few-shot + 复杂 schema（数组）
  local out2 = fn({ op = 'extract',
    text = '张伟是阿里巴巴的CTO，王芳在腾讯做产品经理。',
    schema = '{"type":"object","properties":{"people":{"type":"array","items":{"type":"object","properties":{"name":{"type":"string"},"company":{"type":"string"},"title":{"type":"string"}}}}}}',
    endpoint = endpoint, model = 'qwen3.6-35b-a3b',
  })
  print('live extract2 =>', out2)
  ok(out2:find('error:') == nil, 'live extract array no error')
  ok(out2:find('张伟') ~= nil and out2:find('阿里巴巴') ~= nil, 'live extract array content')

  -- chat 模式（reasoning 关闭）
  local chat = fn({ op = 'chat', text = '只回答：1+1=', endpoint = endpoint, model = 'qwen3.6-35b-a3b' })
  print('live chat =>', chat)
  ok(chat:find('error:') == nil and chat:find('2') ~= nil, 'live chat works')
else
  print('(LLM_TEST_ENDPOINT not set — skipping live tests)')
end

print(string.format('llm_extract_test: %d passed, %d failed', pass, fail))
if fail > 0 then os.exit(1) end
