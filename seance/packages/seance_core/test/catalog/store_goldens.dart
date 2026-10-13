// Byte goldens captured from the pre-move writers; see
// store_golden_test.dart. Each constant is one exact file: adjacent
// literals concatenate with no separator, and the documents are ASCII.

/// The FileServerConfigStore document with sync tuples, a local
/// tombstone tuple, a pulled tombstone and two preserved rows.
const serversGolden =
    r'{"version":1,"servers":[{"id":"srv-alpha","label":"alpha",'
    r'"host":"alpha.example.com","port":22,"username":"root",'
    r'"authMethod":"agent","syncSecret":false,"group":"Production",'
    r'"color":"blue","icon":"database","startDirectory":"/srv/app",'
    r'"excludeFromSync":false,"createdAt":1,"updatedAt":1791892800000},'
    r'{"id":"srv-beta","label":"Beta","host":"beta.example.com","port":2222,'
    r'"username":"deploy","authMethod":"password","secretRef":"secret-beta",'
    r'"jumpHostId":"srv-alpha","syncSecret":true,"excludeFromSync":false,'
    r'"createdAt":2,"updatedAt":1791892800000},{"id":"srv-gamma",'
    r'"label":"Gamma","host":"gamma.example.com","port":22,'
    r'"username":"peer","authMethod":"agent","syncSecret":false,'
    r'"excludeFromSync":false,"createdAt":4,"updatedAt":1791892795000},'
    r'{"label":"no id","futureField":[1,2]},"opaque-row"],'
    r'"syncTuples":{"srv-alpha":{"updatedAt":1791892800000,'
    r'"deviceId":"device-golden"},"srv-beta":{"updatedAt":1791892800000,'
    r'"deviceId":"device-golden"},"srv-doomed":{"updatedAt":1791892800001,'
    r'"deviceId":"device-golden","deleted":true},'
    r'"srv-gamma":{"updatedAt":1791892795000,"deviceId":"device-peer"},'
    r'"srv-remote-gone":{"updatedAt":1791892796000,"deviceId":"device-peer",'
    r'"deleted":true}}}';

/// The FileServerConfigStore document of an install with no sync
/// device id: no `syncTuples` key.
const serversUnsyncedGolden =
    r'{"version":1,"servers":[{"id":"srv-local","label":"local only",'
    r'"host":"local.example.com","port":22,"username":"me",'
    r'"authMethod":"agent","syncSecret":false,"excludeFromSync":false,'
    r'"createdAt":1,"updatedAt":1791892800000}]}';

/// The PersistentLocalRecordStore document with both cursors, clean
/// and dirty rows, tombstones and a displaced winner.
const syncRecordsGolden =
    r'{"version":1,"highWaterSeq":9,"lastAppliedSeq":8,'
    r'"records":[{"id":"srv-alpha","updatedAt":1000,'
    r'"deviceId":"device-peer","deleted":false,"seq":7,"blob":"AQID",'
    r'"dirty":false},{"id":"srv-gone","updatedAt":1100,'
    r'"deviceId":"device-peer","deleted":true,"seq":8,"blob":"",'
    r'"dirty":false},{"id":"bookmark:bm-1","updatedAt":1200,'
    r'"deviceId":"device-golden","deleted":false,"blob":"AQID",'
    r'"dirty":true},{"id":"hostkey:alpha.example.com:22","updatedAt":1300,'
    r'"deviceId":"device-golden","deleted":true,"blob":"","dirty":true},'
    r'{"id":"bookmark:bm-2","updatedAt":1500,"deviceId":"device-golden",'
    r'"deleted":false,"blob":"BwgJ","dirty":true},{"id":"secret:s-1",'
    r'"updatedAt":1400,"deviceId":"device-golden","deleted":false,"seq":10,'
    r'"blob":"AQID","dirty":false}],"displaced":[{"id":"bookmark:bm-2",'
    r'"updatedAt":2000,"deviceId":"device-peer","deleted":false,"seq":9,'
    r'"blob":"BAUG"}]}';
