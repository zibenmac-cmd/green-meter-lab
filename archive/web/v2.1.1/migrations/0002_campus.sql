CREATE TABLE IF NOT EXISTS floors_v21(id TEXT PRIMARY KEY,number INTEGER NOT NULL UNIQUE CHECK(number BETWEEN 1 AND 100),created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS devices_v21(id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL CHECK(kind IN('appliance','floor')),created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS placements_v21(id TEXT PRIMARY KEY,device_id TEXT NOT NULL,floor_id TEXT NOT NULL,valid_from INTEGER NOT NULL,valid_to INTEGER);
CREATE INDEX IF NOT EXISTS placements_v21_device ON placements_v21(device_id,valid_from);
CREATE INDEX IF NOT EXISTS placements_v21_floor ON placements_v21(floor_id,valid_from);
CREATE TRIGGER IF NOT EXISTS placements_v21_no_overlap BEFORE INSERT ON placements_v21 BEGIN
 SELECT CASE WHEN EXISTS(SELECT 1 FROM placements_v21 p WHERE p.device_id=NEW.device_id AND COALESCE(p.valid_to,9223372036854775807)>NEW.valid_from AND COALESCE(NEW.valid_to,9223372036854775807)>p.valid_from) THEN RAISE(ABORT,'设备归属时间重叠') END;
 SELECT CASE WHEN (SELECT kind FROM devices_v21 WHERE id=NEW.device_id)='floor' AND EXISTS(SELECT 1 FROM placements_v21 p JOIN devices_v21 d ON d.id=p.device_id WHERE p.floor_id=NEW.floor_id AND d.kind='floor' AND COALESCE(p.valid_to,9223372036854775807)>NEW.valid_from AND COALESCE(NEW.valid_to,9223372036854775807)>p.valid_from) THEN RAISE(ABORT,'同一楼层同一时间只能有一个总表，避免重复计量') END;
END;
CREATE TABLE IF NOT EXISTS activities_v21(id TEXT PRIMARY KEY,title TEXT NOT NULL,kind TEXT NOT NULL,status TEXT NOT NULL,scheduled_at TEXT,description TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS participation_v21(activity_id TEXT NOT NULL,floor_id TEXT NOT NULL,status TEXT NOT NULL,updated_at INTEGER NOT NULL,PRIMARY KEY(activity_id,floor_id));
