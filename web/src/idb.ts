// IndexedDB persistence for locally-added sessions: raw jsonl text per session,
// so uploads survive page reloads. Nothing is sent to the server here.

export interface StoredSession {
  id: string;
  fileName: string;
  /** Encoded project dir name if the file came from a projects/ folder drop. */
  projectDir: string;
  text: string;
  addedAt: number;
}

const DB_NAME = "session-explorer";
const STORE = "sessions";

function openDB(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      req.result.createObjectStore(STORE, { keyPath: "id" });
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

function tx<T>(mode: IDBTransactionMode, run: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  return openDB().then(
    (db) =>
      new Promise<T>((resolve, reject) => {
        const t = db.transaction(STORE, mode);
        const req = run(t.objectStore(STORE));
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
        t.oncomplete = () => db.close();
      }),
  );
}

export function saveSession(s: StoredSession): Promise<IDBValidKey> {
  return tx("readwrite", (store) => store.put(s));
}

export function loadAllSessions(): Promise<StoredSession[]> {
  return tx("readonly", (store) => store.getAll() as IDBRequest<StoredSession[]>);
}

export function deleteSession(id: string): Promise<undefined> {
  return tx("readwrite", (store) => store.delete(id) as IDBRequest<undefined>);
}

export function clearSessions(): Promise<undefined> {
  return tx("readwrite", (store) => store.clear() as IDBRequest<undefined>);
}
