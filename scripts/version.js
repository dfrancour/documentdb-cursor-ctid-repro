const b = db.adminCommand({ buildInfo: 1 });
print("version\t" + EJSON.stringify({ version: b.version }));
