LOAD '/mnt/d/wsl2/luajit/build/release/luajit.duckdb_extension';
SELECT * FROM luajit_module(mode := 'quick_compile', sql_name := 'ofdprobe',
  source := 'return dofile(''/mnt/d/wsl2/duckdb-luajit-libs/libs/datasource/inv_ofd_probe.lua'')');
SELECT luajit_s('ofdprobe', {}) AS out;
