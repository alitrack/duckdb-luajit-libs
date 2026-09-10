-- E2E 冒烟：psi / entity / privacy 三个新 lib 走 duckdb-luajit SQL 接口
-- 用法: duckdb -c ".read e2e_smoke.sql" （已 FORCE INSTALL 本地 luajit 扩展）
FORCE INSTALL '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
LOAD luajit;

-- psi
SELECT * FROM luajit_module(mode:='install', sql_name:='psi');
SELECT luajit_s('psi', {'op':'psi', 'e':[0.2,0.3,0.3,0.2], 'a':[0.1,0.2,0.3,0.4]}) AS psi_manual;
SELECT luajit_s('psi', {'op':'report', 'raw_e':[1,2,3,4,5,6,7,8,9,10], 'raw_a':[2,3,4,5,6,7,8,9,10,11]}) AS drift_report;

-- entity
SELECT * FROM luajit_module(mode:='install', sql_name:='entity');
SELECT luajit_s('entity', {'v':'Robert', 'mode':'soundex', 'op':'block'}) AS soundex;
SELECT luajit_s('entity', {'a':'martha', 'b':'marhta', 'op':'match'}) AS jw;
SELECT luajit_s('entity', {'op':'resolve',
  'name':['Alice Chen','Alice Chen','Bob Li','Bob Lee','Charlie'],
  'city':['Hangzhou','HZ','Shanghai','SH','Beijing'],
  'id':[1,2,3,4,5],
  'key_fields':['name','city'], 'threshold':0.88}) AS clusters;

-- privacy
SELECT * FROM luajit_module(mode:='install', sql_name:='privacy');
SELECT luajit_s('privacy', {'true_count':1000, 'epsilon':1.0, 'seed':42, 'op':'dp_count'}) AS dp_count;
SELECT luajit_s('privacy', {'v':'13800138000', 'mode':'star', 'op':'mask'}) AS masked;
SELECT luajit_s('privacy', {'op':'kanon',
  'age':[25,26,60,61],
  'city':['hz','hz','sh','sh'],
  'id':[1,2,3,4], 'k':2}) AS kanon;
-- privacy :: CN 合规脱敏 + 临床日期平移（2026-09-10）
SELECT luajit_s('privacy', {'op':'mask_cn', 'kind':'idcard', 'v':'110101199003071234'}) AS cn_idcard;
SELECT luajit_s('privacy', {'op':'mask_cn', 'v':'13800138000'}) AS cn_mobile_auto;
SELECT luajit_s('privacy', {'op':'mask_cn', 'kind':'name', 'v':'欧阳锋'}) AS cn_name;
SELECT luajit_s('privacy', {'op':'dateshift', 'v':'2150-03-04', 'key':'10001', 'days':180, 'with_delta':true}) AS shifted;
SELECT luajit_s('privacy', {'op':'dateoffset', 'key':'10001', 'days':180}) AS offset_days;
-- privacy :: P1 —— k/l/t 效果评估 + ε 预算台账（2026-09-10）
SELECT luajit_s('privacy', {'op':'kanon_report',
  'age':[25,26,60,61], 'city':['hz','hz','sh','sh'], 'disease':['A','B','A','A'],
  'k':2, 'l':2, 't':0.2, 'sensitive_field':'disease'}) AS kanon_report;
SELECT luajit_s('privacy', {'op':'kanon_report',
  'age':[25,26,60,61], 'city':['hz','hz','sh','sh'], 'stage':[1,1,2,3],
  'k':2, 'l':2, 't':0.4, 'ordered':true, 'sensitive_field':'stage'}) AS kanon_report_ordered;
SELECT luajit_s('privacy', {'op':'dp_compose', 'epsilon':0.01, 'count':100, 'delta':1e-5}) AS compose;
SELECT luajit_s('privacy', {'op':'dp_alloc', 'budget':1.0, 'n':100, 'delta':1e-5}) AS alloc;
SELECT luajit_s('privacy', {'op':'dp_budget', 'budget':1.0, 'request':0.3,
  'ledger':[{'epsilon':0.25},{'epsilon':0.25}]}) AS budget;
-- privacy :: P2 —— 自由文本 PHI 脱敏 redact_text（2026-09-10）
SELECT luajit_s('privacy', {'op':'redact_text', 'dict':['张三'],
  'v':'患者张三，电话13800138000，身份证110101199003071234，邮箱zhang.san@hospital.org，入院2026-03-04'}) AS redact;
SELECT luajit_s('privacy', {'op':'redact_text', 'key':'10001', 'days':180,
  'v':'入院2026-03-04 随访2026/05/06'}) AS redact_shifted;
