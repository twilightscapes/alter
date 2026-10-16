//
//  Database.swift
//  Alter
//
//  This Source Code Form is subject to the terms of the Mozilla Public
//  License, v. 2.0. If a copy of the MPL was not distributed with this
//  file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
//  Thin wrapper over the system SQLite — no dependencies. The catalog is the
//  heart of an .alterlib library, so this stays small, explicit, and boring.
//

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum DatabaseError: LocalizedError {
    case open(String)
    case prepare(String, sql: String)
    case step(String, sql: String)

    var errorDescription: String? {
        switch self {
        case .open(let message): return "Couldn't open library: \(message)"
        case .prepare(let message, let sql): return "Catalog error: \(message) [\(sql)]"
        case .step(let message, let sql): return "Catalog error: \(message) [\(sql)]"
        }
    }
}

final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")
    }

    /// Open a database strictly read-only — no journal, no WAL, no lock
    /// files written beside it. For reading someone else's library (an
    /// Aperture bundle) that must stay byte-identical.
    init(readOnlyPath path: String) throws {
        let uri = "file:" + path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?mode=ro&immutable=1"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw DatabaseError.open(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    private var message: String { String(cString: sqlite3_errmsg(handle)) }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError.step(message, sql: sql)
        }
    }

    /// Run a statement with `?` bindings (INSERT/UPDATE/DELETE).
    func run(_ sql: String, _ params: [Any?] = []) throws {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.step(message, sql: sql)
        }
    }

    /// Query rows as dictionaries keyed by column name.
    func query(_ sql: String, _ params: [Any?] = []) throws -> [[String: Any]] {
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }

        var rows: [[String: Any]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw DatabaseError.step(message, sql: sql) }

            var row: [String: Any] = [:]
            let count = sqlite3_column_count(statement)
            for index in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER:
                    row[name] = sqlite3_column_int64(statement, index)
                case SQLITE_FLOAT:
                    row[name] = sqlite3_column_double(statement, index)
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, index) {
                        row[name] = String(cString: text)
                    }
                case SQLITE_BLOB:
                    if let bytes = sqlite3_column_blob(statement, index) {
                        row[name] = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
                    } else {
                        row[name] = Data()
                    }
                default:
                    break // NULL
                }
            }
            rows.append(row)
        }
        return rows
    }

    func scalarInt(_ sql: String, _ params: [Any?] = []) throws -> Int64 {
        let rows = try query(sql, params)
        guard let first = rows.first, let value = first.values.first as? Int64 else { return 0 }
        return value
    }

    private func prepare(_ sql: String, _ params: [Any?]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            throw DatabaseError.prepare(message, sql: sql)
        }
        for (offset, param) in params.enumerated() {
            let index = Int32(offset + 1)
            switch param {
            case nil:
                sqlite3_bind_null(prepared, index)
            case let value as Int64:
                sqlite3_bind_int64(prepared, index, value)
            case let value as Int:
                sqlite3_bind_int64(prepared, index, Int64(value))
            case let value as Bool:
                sqlite3_bind_int64(prepared, index, value ? 1 : 0)
            case let value as Double:
                sqlite3_bind_double(prepared, index, value)
            case let value as String:
                sqlite3_bind_text(prepared, index, value, -1, SQLITE_TRANSIENT)
            default:
                sqlite3_bind_text(prepared, index, String(describing: param!), -1, SQLITE_TRANSIENT)
            }
        }
        return prepared
    }
}
