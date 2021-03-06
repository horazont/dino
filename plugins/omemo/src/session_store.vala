using Signal;
using Qlite;

namespace Dino.Plugins.Omemo {

private class BackedSessionStore : SimpleSessionStore {
    private Database db;
    private int identity_id;

    public BackedSessionStore(Database db, int identity_id) {
        this.db = db;
        this.identity_id = identity_id;
        init();
    }

    private void init() {
        try {
            Address addr = new Address();
            foreach (Row row in db.session.select().with(db.session.identity_id, "=", identity_id)) {
                addr.name = row[db.session.address_name];
                addr.device_id = row[db.session.device_id];
                store_session(addr, Base64.decode(row[db.session.record_base64]));
            }
        } catch (Error e) {
            print(@"OMEMO: Error while initializing session store: $(e.message)\n");
        }

        session_stored.connect(on_session_stored);
        session_removed.connect(on_session_deleted);
    }

    public void on_session_stored(SessionStore.Session session) {
        try {
            db.session.insert().or("REPLACE")
                    .value(db.session.identity_id, identity_id)
                    .value(db.session.address_name, session.name)
                    .value(db.session.device_id, session.device_id)
                    .value(db.session.record_base64, Base64.encode(session.record))
                    .perform();
        } catch (Error e) {
            print(@"OMEMO: Error while updating session store: $(e.message)\n");
        }
    }

    public void on_session_deleted(SessionStore.Session session) {
        try {
            db.session.delete()
                    .with(db.session.identity_id, "=", identity_id)
                    .with(db.session.address_name, "=", session.name)
                    .with(db.session.device_id, "=", session.device_id)
                    .perform();
        } catch (Error e) {
            print(@"OMEMO: Error while updating session store: $(e.message)\n");
        }
    }
}

}