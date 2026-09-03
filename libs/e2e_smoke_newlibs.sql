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
