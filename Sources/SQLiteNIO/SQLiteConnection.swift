import NIO
import CSQLite
import Logging

public final class SQLiteConnection {
    /// Available SQLite storage methods.
    public enum Storage {
        /// In-memory storage. Not persisted between application launches.
        /// Good for unit testing or caching.
        case memory

        /// File-based storage, persisted between application launches.
        case file(path: String)
    }

    public let eventLoop: EventLoop
    internal var handle: OpaquePointer?
    internal let threadPool: NIOThreadPool
    private var logger: Logger

    public var isClosed: Bool {
        return self.handle == nil
    }

    public static func open(
        storage: Storage = .memory,
        threadPool: NIOThreadPool,
        logger: Logger = .init(label: "codes.vapor.sqlite-nio.connection"),
        on eventLoop: EventLoop
    ) -> EventLoopFuture<SQLiteConnection> {
        let path: String
        switch storage {
        case .memory:
            path = ":memory:"
        case .file(let file):
            path = file
        }

        let promise = eventLoop.makePromise(of: SQLiteConnection.self)
        threadPool.submit { state in
            var handle: OpaquePointer?
            let options = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
            if sqlite3_open_v2(path, &handle, options, nil) == SQLITE_OK, sqlite3_busy_handler(handle, { _, _ in 1 }, nil) == SQLITE_OK {
                let connection = SQLiteConnection(
                    handle: handle,
                    threadPool: threadPool,
                    logger: logger,
                    on: eventLoop
                )
                logger.debug("Connected to sqlite db: \(path)")
                promise.succeed(connection)
            } else {
                logger.error("Failed to connect to sqlite db: \(path)")
                promise.fail(SQLiteError(reason: .cantOpen, message: "Cannot open SQLite database: \(storage)"))
            }
        }
        return promise.futureResult
    }

    init(handle: OpaquePointer?, threadPool: NIOThreadPool, logger: Logger, on eventLoop: EventLoop) {
        self.handle = handle
        self.threadPool = threadPool
        self.logger = logger
        self.eventLoop = eventLoop
    }

    public var lastAutoincrementID: Int64? {
        return sqlite3_last_insert_rowid(self.handle)
    }
    
    /// The maximum number of parameters allowed in a single expression
    public var maxVariableNumber: Int {
        return Int(sqlite3_limit(self.handle, SQLITE_LIMIT_VARIABLE_NUMBER, -1))
    }

    internal var errorMessage: String? {
        if let raw = sqlite3_errmsg(self.handle) {
            return String(cString: raw)
        } else {
            return nil
        }
    }

    public func query(_ query: String, _ binds: [SQLiteData] = []) -> EventLoopFuture<[SQLiteRow]> {
        var rows: [SQLiteRow] = []
        return self.query(query, binds) { row in
            rows.append(row)
        }.map { rows }
    }

    public func query(
        _ query: String,
        _ binds: [SQLiteData] = [],
        _ onRow: @escaping (SQLiteRow) throws -> Void
    ) -> EventLoopFuture<Void> {
        self.logger.debug("\(query) \(binds)")
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.threadPool.submit { state in
            do {
                let statement = try SQLiteStatement(query: query, on: self)
                try statement.bind(binds)
                let columns = try statement.columns()
                var callbacks: [EventLoopFuture<Void>] = []
                while let row = try statement.nextRow(for: columns) {
                    let callback = self.eventLoop.submit {
                        try onRow(row)
                    }
                    callbacks.append(callback)
                }
                EventLoopFuture<Void>.andAllComplete(callbacks, on: self.eventLoop)
                    .cascade(to: promise)
            } catch {
                promise.fail(error)
            }
        }
        return promise.futureResult
    }

    public func close() -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.threadPool.submit { state in
            sqlite3_close(self.handle)
            self.eventLoop.submit {
                self.handle = nil
            }.cascade(to: promise)
        }
        return promise.futureResult
    }

    deinit {
        assert(self.handle == nil, "SQLiteConnection was not closed before deinitializing")
    }
}
