//
//  SQLite.swift
//  SnowHaze
//

//  Copyright © 2017 Illotros GmbH. All rights reserved.
//

import Foundation
import Dispatch

private let internalQueue = DispatchQueue(label: "ch.illotros.sqlite.internal")

public extension String {
	private static let escapeRx = try! NSRegularExpression(pattern: "[\\\\%_]")

	public var backslashEscapeLike: String {
		let range = NSRange(startIndex ..< endIndex, in: self)
		return String.escapeRx.stringByReplacingMatches(in: self, range: range, withTemplate: "\\\\$0")
	}

	fileprivate init?(cUTF8: UnsafeRawPointer) {
		self.init(cString: UnsafePointer<Int8>(OpaquePointer(cUTF8)), encoding: .utf8)
	}

	fileprivate init?(cUTF8: UnsafeRawPointer, length: Int32) {
		let data = Data(bytes: cUTF8, count: Int(length))
		self.init(data: data, encoding: .utf8)
	}

	fileprivate func withCUTF8<ResultType>(_ body: (UnsafePointer<Int8>, UInt64) throws -> ResultType) rethrows -> ResultType {
		let cString = utf8CString
		return try cString.withUnsafeBytes {
			return try body(UnsafePointer<Int8>(OpaquePointer($0.baseAddress!)), UInt64(cString.count - 1))
		}
	}

	fileprivate func withShortCUTF8<ResultType>(_ body: (UnsafePointer<Int8>, Int32) throws -> ResultType) throws -> ResultType {
		let cString = utf8CString
		guard let count = Int32(exactly: cString.count - 1) else {
			throw SQLite.error(message: "Strings longer than \(Int32.max) bytes (in UTF-8) are not fully supported by SQLite")
		}
		return try cString.withUnsafeBytes {
			return try body(UnsafePointer<Int8>(OpaquePointer($0.baseAddress!)), count)
		}
	}

	fileprivate func withCUTF8<ResultType>(_ body: (UnsafePointer<Int8>) throws -> ResultType) rethrows -> ResultType {
		return try utf8CString.withUnsafeBytes {
			return try body(UnsafePointer<Int8>(OpaquePointer($0.baseAddress!)))
		}
	}

	private func escape(char: Character) -> String {
		return "\(char)\(replacingOccurrences(of: "\(char)", with: "\(char)\(char)"))\(char)"
	}

	var sqliteEscaped: String {
		return escape(char: "'")
	}

	var sqliteEscapedIdentifier: String {
		return escape(char: "\"")
	}
}

private extension Int {
	var clampedTo32Bit: Int32 {
		guard self < Int(Int32.max) else {
			return Int32.max
		}
		guard self > Int(Int32.min) else {
			return Int32.min
		}
		return Int32(self)
	}
}

public extension Data {
	var sqliteEscaped: String {
		return "x'" + reduce("") { $0 + String(format: "%02x", $1) } + "'"
	}

	fileprivate func withUnsafeBytes<ResultType, ContentType>(_ body: (UnsafePointer<ContentType>, UInt64) throws -> ResultType) rethrows -> ResultType {
		return try self.withUnsafeBytes { return try body($0, UInt64(count)) }
	}
}

public class SQLite {
	public enum Error: Swift.Error {
		case error(String?)
		case sqliteDBLocked(String?)
		case sqliteSwiftError(String)
		case aborted
		case misuse
		case busy
		case other(String?, Int)
	}

	public enum Data: Equatable {
		case text(String)
		case integer(Int64)
		case float(Double)
		case blob(Foundation.Data)
		case null

		static let `true` = integer(1)
		static let `false` = integer(0)
		static func bool(_ value: Bool) -> SQLite.Data {
			return Data(value)
		}

		public var text: String? {
			if case .text(let text) = self {
				return text
			}
			return nil
		}

		public var textValue: String? {
			switch self {
				case .text(let text):	return text
				case .float(let float):	return "\(float)"
				case .integer(let int):	return "\(int)"
				case .blob(let data):	return String(data: data, encoding: .utf8)
				case .null:				return nil
			}
		}

		public var float: Double? {
			if case .float(let float) = self {
				return float
			}
			return nil
		}

		public var floatValue: Double? {
			switch self {
				case .text(let text):
					return Double(text)
				case .float(let float):
					return float
				case .integer(let int):
					return Double(int)
				case .blob(let data):
					guard let string = String(data: data, encoding: .utf8) else {
						return nil
					}
					return Double(string)
				case .null:
					return nil
			}
		}

		public var integer: Int64? {
			if case .integer(let int) = self {
				return int
			}
			return nil
		}

		public var integerValue: Int64? {
			switch self {
				case .text(let text):
					return Int64(text)
				case .float(let float):
					return Int64(float)
				case .integer(let int):
					return int
				case .blob(let data):
					guard let string = String(data: data, encoding: .utf8) else {
						return nil
					}
					return Int64(string)
				case .null:
					return nil
			}
		}

		public var blob: Foundation.Data? {
			if case .blob(let data) = self {
				return data
			}
			return nil
		}

		public var blobValue: Foundation.Data? {
			switch self {
				case .text(let text):	return text.data(using: .utf8)
				case .float(let float):	return "\(float)".data(using: .utf8)
				case .integer(let int):	return "\(int)".data(using: .utf8)
				case .blob(let data):	return data
				case .null:				return nil
			}
		}

		public var bool: Bool? {
			switch integer {
				case .some(0):	return false
				case .some(1):	return true
				default:		return nil
			}
		}

		public var boolValue: Bool {
			return (floatValue ?? 0) != 0
		}

		public var isNull: Bool {
			return self == .null
		}

		public init(_ data: Foundation.Data?) {
			if let data = data {
				self = .blob(data)
			} else {
				self = .null
			}
		}

		public init(_ bool: Bool) {
			self = .integer(bool ? 1 : 0)
		}

		public init(_ string: String?) {
			if let string = string {
				self = .text(string)
			} else {
				self = .null
			}
		}

		public static func ==(t1: Data, t2: Data) -> Bool {
			switch (t1, t2) {
				case (.text(let s1), .text(let s2)):		return s1 == s2
				case (.blob(let b1), .blob(let b2)):		return b1 == b2
				case (.integer(let i1), .integer(let i2)):	return i1 == i2
				case (.float(let f1), .float(let f2)):		return f1 == f2
				case (.null, .null):						return true
				default:									return false
			}
		}
	}

	public enum Option {
		/// set threading mode to singlethread
		case singlethread

		/// set threading mode to multithread
		case multithread

		/// set threading mode to serialized
		case serialized

	//	case malloc							/// not supported
	//	case getMalloc						/// not supported

		/// enable or disable data collection for memory usage statistics
		case memStatus(Bool)
	//	case scratch						/// not supported
	//	case pageCache						/// not supported
	//	case heap							/// not supported
	//	case mutex							/// not supported
	//	case getMutes						/// not supported
	//	case lookaside						/// not supported
	//	case pcache2						/// not supported
	//	case getPcache2						/// not supported

		/// set the callback for sqlite3_log(...). the callback function may not call SQLite functions and musst be threadsafe if multiple threads use SQLite
		case log(((Int, String) -> Void)?)

		/// enable or disable handling of file: URIs in sqlite3_open(...)
		case uri(Bool)

		/// set the default and maximum size limit for mmap
		case mmapSize(Int, Int)
	//	case win32HeapSize					/// windows only option
	//	case pcacheHeaderSize				/// not supported

		/// set the "Minimum PMA Size" for the multithreaded sorter
		case minimumPmaSize(UInt)

		/// set the minimum size at which statement journals spill to disk
		case statementJournalSpill(Int)
	}

	public enum DBOption {
	//	case mainDBName						/// not supported

		/// configure size and number of lookaside slots
		case lookaside(UnsafeMutableRawPointer?, Int, Int)

		/// enable, disable or query status of forein key enforcement
		case foreinKey(Bool?)

		/// enable, disable or query status of trigger support
		case trigger(Bool?)

		/// enable, disable or query status of two-argument version of fts3_tokenizer()
		case fts3Tokenizer(Bool?)

		/// enable, disable or query status of the sqlite3_load_extension() interface
		case loadExtension(Bool?)

		/// turn off, turn on or query status of checkpoints when database is closed
		case noCheckpointOnClose(Bool?)

		/// enable, disable or query status of the query planer stability guarantee
		case queryPlannerStabilityGuarantee(Bool?)

		/// enable, disable or query status of explain query plan including triggers in explanation
		case triggerExplainQueryPlan(Bool?)
	}

	public enum BindingKey: Hashable {
		case alphanumeric(String)
		case numeric(Int)

		public var hashValue: Int {
			switch self {
				case .alphanumeric(let str):	return str.hashValue
				case .numeric(let int):			return int.hashValue
			}
		}

		public static func ==(_ a: BindingKey, _ b: BindingKey) -> Bool {
			switch (a, b) {
				case (.alphanumeric(let aString), .alphanumeric(let bString)):
					return aString == bString
				case (.numeric(let aInt), .numeric(let bInt)):
					return aInt == bInt
				default:
					return false
			}
		}
	}

	public class Statement {
		public struct PrepareOptions: OptionSet {
			public let rawValue: UInt32

			public init(rawValue value: UInt32) {
				rawValue = value
			}

			public static let persistent	= PrepareOptions(rawValue: UInt32(SQLITE_PREPARE_PERSISTENT))
		}

		private let statement: OpaquePointer
		fileprivate lazy var dataCount32: Int32 = sqlite3_data_count(self.statement)

		public private(set) lazy var sql: String = String(cUTF8: sqlite3_sql(self.statement))!
		public private(set) lazy var isReadonly: Bool = sqlite3_stmt_readonly(self.statement) != 0
		private lazy var handle: OpaquePointer = sqlite3_db_handle(self.statement)

		public var dataCount: Int { return Int(dataCount32) }

		public private(set) lazy var columns: [String] = {
			var res = [String]()
			res.reserveCapacity(Int(self.dataCount))
			for i in 0 ..< self.dataCount32 {
				res.append(String(cUTF8: sqlite3_column_name(self.statement, i))!)
			}
			return res
		}()

		fileprivate private(set) lazy var columnMapping: [String: Int32] = {
			var res = [String: Int32]()
			for (i, name) in self.columns.enumerated() {
				res[self.columns[i]] = Int32(i)
			}
			return res
		}()

		public var expandedSql: String {
			let cSql = sqlite3_expanded_sql(self.statement)!
			let ret = String(cUTF8: cSql)!
			sqlite3_free(cSql)
			return ret
		}

		public var isBusy: Bool {
			return sqlite3_stmt_busy(statement) != 0
		}

		var row: Row {
			return Row(statement: self)
		}

		public var prefetchedRow: Row {
			return row.loaded
		}

		public func reset() throws {
			try check(sqlite3_reset(statement), connection: handle)
		}

		public func clearBindings() throws {
			try check(sqlite3_clear_bindings(statement), connection: handle)
		}

		fileprivate init?(connection: SQLite, sql: String, options: PrepareOptions) throws {
			var statement: OpaquePointer? = nil
			try sql.withShortCUTF8 {
				try connection.check(sqlite3_prepare_v3(connection.connection, $0, $1, options.rawValue, &statement, nil))
			}
			guard let stmt = statement else {
				return nil
			}
			self.statement = stmt
		}

		fileprivate init?(connection: SQLite, sql: String, tail: inout String, options: PrepareOptions) throws {
			var statement: OpaquePointer? = nil
			var pzTail: UnsafePointer<Int8>? = nil
			try sql.withShortCUTF8 {
				try connection.check(sqlite3_prepare_v3(connection.connection, $0, $1, options.rawValue, &statement, &pzTail))
			}

			if let pzTail = pzTail {
				tail = String(cUTF8: pzTail)!
			} else {
				tail = ""
			}

			guard let stmt = statement else {
				return nil
			}
			self.statement = stmt
		}

		fileprivate func bind(pointer: UnsafeMutableRawPointer, ofType type: UnsafePointer<Int8>, to index: Int32, destuctor: (@convention(c) (UnsafeMutableRawPointer?) -> Void)? = nil) throws {
			try check(sqlite3_bind_pointer(statement, index, pointer, type, destuctor), connection: handle)
		}

		public func bind(_ value: Data, to keyIndex: Int) throws {
			try bind(value, to: keyIndex.clampedTo32Bit)
		}

		public func bind(_ value: Data, to keyIndex: Int32) throws {
			switch value {
				case .null:
					try check(sqlite3_bind_null(statement, keyIndex), connection: handle)
				case .integer(let int):
					try check(sqlite3_bind_int64(statement, keyIndex, int), connection: handle)
				case .float(let float):
					try check(sqlite3_bind_double(statement, keyIndex, float), connection: handle)
				case .text(let text):
					let res = text.withCUTF8 { sqlite3_bind_text64(statement, keyIndex, $0, $1, TRANSIENT, UInt8(SQLITE_UTF8)) }
					try check(res, connection: handle)
				case .blob(let data):
					let res = data.withUnsafeBytes { sqlite3_bind_blob64(statement, keyIndex, $0, $1, TRANSIENT) }
					try check(res, connection: handle)
			}
		}

		public func bind(_ value: Data, to key: String) throws {
			let keyIndex = key.withCUTF8 { sqlite3_bind_parameter_index(statement, $0) }
			try bind(value, to: keyIndex)
		}

		public func bind(_ value: Data, to key: BindingKey) throws {
			switch key {
				case .numeric(let int):			try bind(value, to: int)
				case .alphanumeric(let string): try bind(value, to: string)
			}
		}

		public func bind(_ values: [BindingKey: Data]) throws {
			for (key, data) in values {
				try bind(data, to: key)
			}
		}

		public func bind(_ values: [Data]) throws {
			for (index, data) in values.enumerated() {
				let keyIndex = index + 1
				try bind(data, to: keyIndex)
			}
		}

		public func bind(_ values: [String: Data]) throws {
			for (key, data) in values {
				try bind(data, to: key)
			}
		}

		public func bind(_ values: [Int: Data]) throws {
			for (key, data) in values {
				try bind(data, to: key)
			}
		}

		@discardableResult public func execute(with bindings: [BindingKey: Data]) throws -> [Row] {
			try bind(bindings)
			return try execute()
		}

		@discardableResult public func execute(with bindings: [Data]) throws -> [Row] {
			try bind(bindings)
			return try execute()
		}

		@discardableResult public func execute(with bindings: [Int: Data]) throws -> [Row] {
			try bind(bindings)
			return try execute()
		}

		@discardableResult public func execute(with bindings: [String: Data]) throws -> [Row] {
			try bind(bindings)
			return try execute()
		}

		@discardableResult public func execute() throws -> [Row] {
			var ret = [Row]()
			while try step() {
				ret.append(prefetchedRow)
			}
			return ret
		}

		public func execute(callback: (Row) -> Bool) throws {
			while try step() {
				if !callback(row) {
					throw Error.aborted
				}
			}
		}

		// returns true if more data is available
		@discardableResult public func step() throws -> Bool {
			let stepResult = sqlite3_step(statement)
			try check(stepResult, connection: handle, allowed: [SQLITE_ROW, SQLITE_DONE])
			return stepResult == SQLITE_ROW
		}

		public func data(at index: Int) -> Data {
			return data(at: index.clampedTo32Bit)
		}

		public func data(at index: Int32) -> Data {
			let type = sqlite3_column_type(statement, index)
			switch type {
				case SQLITE_TEXT:
					let length = sqlite3_column_bytes(statement, index)
					let bytes = sqlite3_column_text(statement, index)!
					return .text(String(cUTF8: bytes, length: length)!)
				case SQLITE_BLOB:
					let length = sqlite3_column_bytes(statement, index)
					let bytes = sqlite3_column_blob(statement, index)!
					let cnvt = UnsafePointer<UInt8>(OpaquePointer(bytes))
					return .blob(Foundation.Data(bytes: cnvt, count: Int(length)))
				case SQLITE_INTEGER:
					return .integer(sqlite3_column_int64(statement, index))
				case SQLITE_FLOAT:
					return .float(sqlite3_column_double(statement, index))
				case SQLITE_NULL:
					return .null
				default:
					fatalError("Unknown Value Type")
			}
		}

		deinit {
			sqlite3_finalize(statement)
		}
	}

	public class Row: CustomStringConvertible {
		fileprivate let statement: Statement
		fileprivate var dataCount32: Int32 { return statement.dataCount32 }

		public var isLazy: Bool { return true }
		public var columns: [String] { return statement.columns }
		public var dataCount: Int { return statement.dataCount }

		public subscript(index: Int32) -> Data? {
			if index < dataCount32 && index >= 0 {
				return statement.data(at: index)
			} else {
				return nil
			}
		}

		public subscript(index: Int) -> Data? {
			guard let index32 = Int32(exactly: index) else {
				return nil
			}
			return self[index32]
		}

		public subscript(key: String) -> Data? {
			if let index = statement.columnMapping[key] {
				return statement.data(at: index)
			} else {
				return nil
			}
		}

		fileprivate init(statement: Statement) {
			self.statement = statement
		}

		public var loaded: Row {
			return PrefetchedRow(statement: statement)
		}

		public var description: String {
			let descs = (0 ..< dataCount).map { "\(columns[Int($0)]): \(self[$0] ?? .null)" }
			return descs.joined(separator: ", ")
		}

		private var singleColumn: Data? {
			return dataCount == 1 ? self[0] : nil
		}

		public var text: String? {
			return singleColumn?.text
		}

		public var textValue: String? {
			return singleColumn?.textValue
		}

		public var float: Double? {
			return singleColumn?.float
		}

		public var floatValue: Double? {
			return singleColumn?.floatValue
		}

		public var integer: Int64? {
			return singleColumn?.integer
		}

		public var integerValue: Int64? {
			return singleColumn?.integerValue
		}

		public var blob: Foundation.Data? {
			return singleColumn?.blob
		}

		public var blobValue: Foundation.Data? {
			return singleColumn?.blobValue
		}

		public var bool: Bool? {
			return singleColumn?.bool
		}

		public var boolValue: Bool? {
			return singleColumn?.boolValue
		}

		public var isNull: Bool? {
			return singleColumn?.isNull
		}
	}

	private class PrefetchedRow: Row {
		private let data: [Data]

		override var isLazy: Bool {
			return false
		}

		override subscript (index: Int32) -> Data? {
			if index < dataCount32 && index >= 0 {
				return data[Int(index)]
			} else {
				return nil
			}
		}

		override subscript (key: String) -> Data? {
			if let index = statement.columnMapping[key] {
				return data[Int(index)]
			} else {
				return nil
			}
		}

		fileprivate override init(statement: Statement) {
			let count = statement.dataCount32
			var data = [Data](repeating: .null, count: Int(count))
			for i in 0 ..< count {
				data[Int(i)] = statement.data(at: i)
			}
			self.data = data
			super.init(statement: statement)
		}

		override var loaded: Row {
			return self
		}
	}

	public class Backup {
		private let backup: OpaquePointer

		public var pageCount: Int {
			return Int(sqlite3_backup_pagecount(backup))
		}

		public var remaining: Int {
			return Int(sqlite3_backup_remaining(backup))
		}

		public var progress: Double {
			return 1 - Double(remaining) / Double(pageCount)
		}

		public func updatedPageCount() throws -> Int {
			try! step(pages: 0)
			return pageCount
		}

		public func updatedRemaining() throws -> Int {
			try! step(pages: 0)
			return remaining
		}

		public func updatedProgress() throws -> Double {
			try! step(pages: 0)
			return progress
		}

		public func step(pages: Int = -1) throws {
			let rc = sqlite3_backup_step(backup, pages.clampedTo32Bit)
			guard rc == SQLITE_OK || rc == SQLITE_DONE else {
				throw SQLite.error(code: rc)
			}
		}

		public init?(source: SQLite, sName: String = "main", destination: SQLite, dName: String = "main") {
			let initialized =
				dName.withCUTF8 { dUTF8 in
					sName.withCUTF8 { sUTF8 in
						sqlite3_backup_init(destination.connection, dUTF8, source.connection, sUTF8)
					}
				}
			guard let bk = initialized else {
				return nil
			}
			backup = bk
		}

		deinit {
			sqlite3_backup_finish(backup)
		}
	}

	private let connection: OpaquePointer

	private lazy var fts5APIStmt = (try? statement(for: "SELECT fts5(?)")) ?? nil

	private lazy var beginDefferedStmt = try! statement(for: "BEGIN DEFERRED")!
	private lazy var beginImmediateStmt = try! statement(for: "BEGIN IMMEDIATE")!
	private lazy var beginExclusiveStmt = try! statement(for: "BEGIN EXCLUSIVE")!
	private lazy var endStmt = try! statement(for: "END")!
	private lazy var rollbackStmt = try! statement(for: "ROLLBACK")!

	public struct OpenFlags: OptionSet {
		public let rawValue: Int32

		public init(rawValue value: Int32) {
			rawValue = value
		}

		public static let readonly		= OpenFlags(rawValue: SQLITE_OPEN_READONLY)
		public static let readwrite		= OpenFlags(rawValue: SQLITE_OPEN_READWRITE)
		public static let create		= OpenFlags(rawValue: SQLITE_OPEN_CREATE)
		public static let uri			= OpenFlags(rawValue: SQLITE_OPEN_URI)
		public static let memory		= OpenFlags(rawValue: SQLITE_OPEN_MEMORY)
		public static let nomutex		= OpenFlags(rawValue: SQLITE_OPEN_NOMUTEX)
		public static let fullmutex		= OpenFlags(rawValue: SQLITE_OPEN_FULLMUTEX)
		public static let sharedcache	= OpenFlags(rawValue: SQLITE_OPEN_SHAREDCACHE)
		public static let privatecache	= OpenFlags(rawValue: SQLITE_OPEN_PRIVATECACHE)

		public static let rwCreate: OpenFlags = [.readwrite, .create]
	}

	public convenience init?(path: String = ":memory:", flags: OpenFlags = .rwCreate) {
		self.init(path: path, finalSetup: "", openName: path, flags: flags)
	}

	public convenience init?(url: URL, flags: OpenFlags = .rwCreate) {
		guard url.isFileURL else {
			return nil
		}
		self.init(path: url.path, finalSetup: "", openName: url.absoluteString, flags: [flags, .uri])
	}

	// finalSetup is only intended for use in subclasses like SQLCipher, in order to ensure database is readable before sanity check is performed. pass empty string if not used.
	internal init?(path: String, finalSetup: String, openName: String, flags: OpenFlags) {
#if os(OSX) || os(iOS)
		var pathComponents = (path as NSString).pathComponents
		_ = pathComponents.popLast()
		let dirPath = NSString.path(withComponents: pathComponents)
		let fileManager = FileManager.default
		if !dirPath.isEmpty && !fileManager.fileExists(atPath: dirPath) {
			guard let _ = try? fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true, attributes: nil) else {
				return nil
			}
		}
#endif

		var tmpConnection: OpaquePointer? = nil
		let openResult = openName.withCUTF8 { sqlite3_open_v2($0, &tmpConnection, flags.rawValue, nil) }
		connection = tmpConnection!
		guard openResult == SQLITE_OK else {
			sqlite3_close(connection)
			return nil
		}

		do {
			if !finalSetup.isEmpty {
				try execute(finalSetup)
			}
			try execute("SELECT count(*) FROM sqlite_master")
		} catch _ {
			sqlite3_close(connection)
			return nil
		}
	}

	public func has(table: String, in db: String = "main") -> Bool {
		let escDB = db.sqliteEscapedIdentifier
		let escTable = table.sqliteEscapedIdentifier
		let res = try? execute("PRAGMA \(escDB).table_info(\(escTable))")
		return res?.count ?? 0 > 0
	}

	/**
	 *	Calls callback for every row returned when running query
	 *
	 *	- parameter query: a semicolon separated list of SQL statements to execute
	 *
	 *	- parameter callback: returns true if the execution should continue. If false is returned, a `aborted` error is thrown.
	 *	NOTE: the row passed to callback is only valid until callback returns. If the data is needed after callback returns, use SQLite.Row.loaded to create a copy, which is valid outside of the scope of callback.
	 */
	public func execute(_ query: String, callback: (Row) -> Bool) throws {
		var query = query
		while !query.isEmpty {
			guard let statement = try Statement(connection: self, sql: query, tail: &query, options: []) else {
				throw error(message: "could not initialize statement for '\(query)'")
			}

			try statement.execute(callback: callback)
		}
	}

	@discardableResult public func execute(_ query: String) throws -> [Row] {
		guard let statement = try statement(for: query) else {
			throw error(message: "could not initialize statement for '\(query)'")
		}
		return try statement.execute()
	}

	@discardableResult public func execute(_ query: String, with bindings: [BindingKey: Data]) throws -> [Row] {
		guard let statement = try statement(for: query) else {
			throw error(message: "could not initialize statement for '\(query)'")
		}
		return try statement.execute(with: bindings)
	}

	@discardableResult public func execute(_ query: String, with bindings: [Data]) throws -> [Row] {
		guard let statement = try statement(for: query) else {
			throw error(message: "could not initialize statement for '\(query)'")
		}
		return try statement.execute(with: bindings)
	}

	@discardableResult public func execute(_ query: String, with bindings: [Int: Data]) throws -> [Row] {
		guard let statement = try statement(for: query) else {
			throw error(message: "could not initialize statement for '\(query)'")
		}
		return try statement.execute(with: bindings)
	}

	@discardableResult public func execute(_ query: String, with bindings: [String: Data]) throws -> [Row] {
		guard let statement = try statement(for: query) else {
			throw error(message: "could not initialize statement for '\(query)'")
		}
		return try statement.execute(with: bindings)
	}

	public func statement(for query: String, options: Statement.PrepareOptions = []) throws -> Statement? {
		return try Statement(connection: self, sql: query, options: options)
	}

	private func error(code: Int32 = -1, message: String? = nil) -> Error {
		return SQLite.error(code: code, connection: connection, message: message)
	}

	private static func error(code: Int32 = -1, connection: OpaquePointer, message: String? = nil) -> Error {
		let fallbackMessage = code >= 0 ? String(cUTF8: sqlite3_errmsg(connection)) : nil
		return error(code: code, message: message ?? fallbackMessage)
	}

	fileprivate static func error(code: Int32 = -1, message: String? = nil) -> Error {
		let info: String?
		if let message = message {
			let codeDesc = String(cUTF8: sqlite3_errstr(code)) ?? "Error"
			info = codeDesc + " " + message
		} else {
			info = nil
		}
		switch code {
			case -1:
				return .sqliteSwiftError(message ?? "Unknow Database Error")
			case SQLITE_ERROR:
				return .error(info)
			case SQLITE_MISUSE:
				return .misuse
			case SQLITE_BUSY:
				return .busy
			case SQLITE_LOCKED:
				return .sqliteDBLocked(info)
			default:
				return .other(info, Int(code))
		}
	}

	private func check(_ result: Int32, allowed: [Int32] = [SQLITE_OK]) throws {
		try SQLite.check(result, connection: connection)
	}

	private static func check(_ result: Int32, connection: OpaquePointer, allowed: [Int32] = [SQLITE_OK]) throws {
		if !allowed.contains(result) {
			throw error(code: result, connection: connection)
		}
	}

	public static func set(option: Option) throws {
		let result = internalQueue.sync { () -> Int32 in
			switch option {
				case .singlethread:
					return sqlite_option_no_param(SQLITE_CONFIG_SINGLETHREAD)
				case .multithread:
					return sqlite_option_no_param(SQLITE_CONFIG_MULTITHREAD)
				case .serialized:
					return sqlite_option_no_param(SQLITE_CONFIG_SERIALIZED)
				case .memStatus(let set):
					return sqlite_option_one_int(SQLITE_CONFIG_MEMSTATUS, set ? 1 : 0)
				case .log(let callback):
					typealias LogFunction = ContextWrapper<(Int, String) -> Void>
					let context = LogFunction(data: callback)
					return sqlite_option_context_context_int_string_fnpointer_int64(SQLITE_CONFIG_LOG, context?.toC) { cContext, code, cString in
						let string = String(cUTF8: cString!)!
						let callback = LogFunction.fromC(cContext!)
						callback.data(Int(code), string)
					}
				case .uri(let set):
					return sqlite_option_one_int(SQLITE_CONFIG_URI, set ? 1 : 0)
				case .mmapSize(let df, let max):
					return sqlite_option_two_int64(SQLITE_CONFIG_MMAP_SIZE, Int64(df), Int64(max))
				case .minimumPmaSize(let sz):
					let sz32 = UInt32(exactly: sz) ?? UInt32.max
					return sqlite_option_one_int(SQLITE_CONFIG_PMASZ, Int32(bitPattern: sz32))
				case .statementJournalSpill(let spill):
					return sqlite_option_one_int(SQLITE_CONFIG_STMTJRNL_SPILL, spill.clampedTo32Bit)
			}
		}
		guard result == SQLITE_OK else {
			throw Error.misuse
		}
	}

	public func set(option: DBOption) throws -> Bool! {
		let (ok, result) = internalQueue.sync { () -> (Int32, Bool?) in
			let enable: Bool?
			let verb: Int32
			switch option {
				case .lookaside(let pointer, let sizeInt, let slotsInt):
					let size = sizeInt.clampedTo32Bit
					let slots = slotsInt.clampedTo32Bit
					let verb = SQLITE_DBCONFIG_LOOKASIDE
					let ok = sqlite_db_option_voidp_int_int(connection, verb, pointer, size, slots)
					return (ok, nil)
				case .foreinKey(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_FKEY
				case .trigger(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_TRIGGER
				case .fts3Tokenizer(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER
				case .loadExtension(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER
				case .noCheckpointOnClose(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER
				case .queryPlannerStabilityGuarantee(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER
				case .triggerExplainQueryPlan(let e):
					enable = e
					verb = SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER
			}
			let set: Int32
			if let enable = enable {
				set = enable ? 1 : 0
			} else {
				set = -1
			}
			var out = Int32()
			let ok = sqlite_db_option_int_intp(connection, verb, set, &out)
			return (ok, out != 0)
		}
		try check(ok)
		return result
	}

	@discardableResult public static func free(_ bytes: Int) -> Int {
		return Int(sqlite3_release_memory(bytes.clampedTo32Bit))
	}

	public func free() throws {
		try check(sqlite3_db_release_memory(connection))
	}

	public func busyTimeout(_ ms: Int) throws {
		try check(sqlite3_busy_timeout(connection, ms.clampedTo32Bit))
	}

	public func filename(for db: String) -> String? {
		return db.withCUTF8 { String(cUTF8: sqlite3_db_filename(connection, $0)) }
	}

	public static func enableSharedCache(_ enable: Bool) {
		sqlite3_enable_shared_cache(enable ? 1 : 0)
	}

	public var lastInsertRowId: Int64 {
		return sqlite3_last_insert_rowid(connection)
	}

	public var changes: Int {
		return Int(sqlite3_changes(connection))
	}

	public var totalChanges: Int {
		return Int(sqlite3_total_changes(connection))
	}

	public static var threadsafe: Bool {
		return sqlite3_threadsafe() != 0
	}

	public static var version: String {
		return String(cUTF8: sqlite3_libversion())!
	}

	public static var versionNumber: Int {
		return Int(sqlite3_libversion_number())
	}

	deinit {
		sqlite3_close_v2(connection)
	}
}

// custom convenience APIs
public extension SQLite {
	public enum TransactionType {
		case deferred
		case immediate
		case exclusive
	}

	public func inTransaction<T>(ofType type: TransactionType = .deferred, perform body: () throws -> T) throws -> T {
		do {
			switch type {
				case .deferred:		try beginDefferedStmt.execute()
				case .immediate:	try beginImmediateStmt.execute()
				case .exclusive:	try beginExclusiveStmt.execute()
			}
			let result = try body()
			try endStmt.execute()
			return result
		} catch {
			_ = try? rollbackStmt.execute()
			throw error
		}
	}

	public func inSavepointBlock(name: String? = nil, perform body: () throws -> Void) throws {
		let savepointName = (name ?? "ch.illotros.sqlite.convenience.safepoint.name").sqliteEscaped
		do {
			try execute("SAVEPOINT \(savepointName)")
			try body()
			try execute("RELEASE \(savepointName)")
		} catch {
			try execute("ROLLBACK TO \(savepointName)")
			throw error
		}
	}
}

// custom functions, aggregates & collations
public extension SQLite {
	private typealias FunctionContext = ContextWrapper<([Data], (Int, Any) -> Void, (Int) -> Any?) throws -> Data>
	private typealias ObjWrapper = ContextWrapper<Any?>

	public func register(name: String, nArgs: Int = 1, deterministic: Bool = true, function: @escaping ([Data]) throws -> Data) throws {
		let fn: ([Data], (Int, Any) -> Void, (Int) -> Any?) throws -> Data = { data, _, _ in return try function(data) }
		try register(name: name, nArgs: nArgs, deterministic: deterministic, function: fn)
	}

	public func register<T>(name: String, nArgs: Int = 1, deterministic: Bool = true, function: @escaping ([Data], (Int, T) -> Void, (Int) -> T?) throws -> Data) throws {
		let encoding = deterministic ? SQLITE_UTF8 | SQLITE_DETERMINISTIC : SQLITE_UTF8
		let cFunction: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { sqliteContext, count, params in
			let context = FunctionContext.fromC(sqlite3_user_data(sqliteContext)!)
			var swiftParams = [Data]()
			swiftParams.reserveCapacity(Int(count))
			for index in 0 ..< count {
				swiftParams.append(SQLite.value(from: params!, index: index))
			}
			let setter: (Int, Any) -> Void = {
				sqlite3_set_auxdata(sqliteContext, $0.clampedTo32Bit, ObjWrapper(data: $1).toC, { ObjWrapper.releaseC($0) })
			}
			let getter: (Int) -> Any? = { ObjWrapper.fromC(sqlite3_get_auxdata(sqliteContext, $0.clampedTo32Bit))?.data! }
			SQLite.perform(inContext: sqliteContext) {
				let result = try context.data(swiftParams, setter, getter)
				SQLite.set(result, context: sqliteContext)
			}
		}
		let contextObj = FunctionContext() { values, set, get in
			try function(values, set, { get($0) as! T? })
		}
		let cContext = contextObj.toC
		try name.withCUTF8 {
			try check(sqlite3_create_function_v2(connection, $0, nArgs.clampedTo32Bit, encoding, cContext, cFunction, nil, nil, { FunctionContext.releaseC($0) }))
		}
	}
	public func register<T>(name: String, nArgs: Int = 1, deterministic: Bool = true, step: @escaping ([Data], T?) throws -> T, final: @escaping (T?) throws -> Data) throws {
		typealias AggregateContext = ContextWrapper<(step: ([Data], Any?) throws -> Any, final: (Any?) throws -> Data)>

		let encoding = deterministic ? SQLITE_UTF8 | SQLITE_DETERMINISTIC : SQLITE_UTF8

		let cStep: @convention(c) (OpaquePointer?, Int32, UnsafeMutablePointer<OpaquePointer?>?) -> Void = { sqliteContext, count, params in
			let context = AggregateContext.fromC(sqlite3_user_data(sqliteContext)!)
			let allocated = sqlite3_aggregate_context(sqliteContext, Int32(MemoryLayout<OpaquePointer>.size))!
			let cAccumulator = UnsafePointer<UnsafeMutableRawPointer?>(OpaquePointer(allocated)).pointee
			let accumulator: ObjWrapper
			if let ptr = cAccumulator {
				accumulator = ObjWrapper.fromC(ptr)
			} else {
				accumulator = ObjWrapper(data: nil)
				UnsafeMutablePointer<UnsafeMutableRawPointer?>(OpaquePointer(allocated)).pointee = accumulator.toC
			}
			var swiftParams = [Data]()
			swiftParams.reserveCapacity(Int(count))
			for index in 0 ..< count {
				swiftParams.append(SQLite.value(from: params!, index: index))
			}
			SQLite.perform(inContext: sqliteContext) {
				let result = try context.data.step(swiftParams, accumulator.data)
				accumulator.data = result
			}
		}

		let cFinal: @convention(c) (OpaquePointer?) -> Void = { sqliteContext in
			let context = AggregateContext.fromC(sqlite3_user_data(sqliteContext)!)
			let allocated = sqlite3_aggregate_context(sqliteContext, Int32(MemoryLayout<OpaquePointer>.size))!
			let ptr = UnsafePointer<UnsafeMutableRawPointer?>(OpaquePointer(allocated)).pointee
			SQLite.perform(inContext: sqliteContext) {
				let result = try context.data.final(ObjWrapper.fromC(ptr)?.data)
				ObjWrapper.releaseC(ptr)
				SQLite.set(result, context: sqliteContext)
			}
		}

		let contextObj = AggregateContext(data: (step: { try step($0, $1 as! T?) }, final: { try final($0 as! T?) }))
		let cContext = contextObj.toC

		try name.withCUTF8 {
			try check(sqlite3_create_function_v2(connection, $0, nArgs.clampedTo32Bit, encoding, cContext, nil, cStep, cFinal, { FunctionContext.releaseC($0) }))
		}
	}

	public func unregister(functionName: String, nArgs: Int = 1) throws {
		try functionName.withCUTF8 {
			try check(sqlite3_create_function_v2(connection, $0, nArgs.clampedTo32Bit, SQLITE_UTF8, nil, nil, nil, nil, nil))
		}
	}

	public func register(name: String, collation: @escaping (String, String) -> ComparisonResult) throws {
		typealias CollationContext = ContextWrapper<(String, String) -> ComparisonResult>
		
		let context = CollationContext(data: collation)
		let cmp: @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeRawPointer?, Int32, UnsafeRawPointer?) -> Int32 = { ptr, l1, b1, l2, b2 in
			let collation = CollationContext.fromC(ptr!).data
			let s1 = String(cUTF8: b1!, length: l1)!
			let s2 = String(cUTF8: b2!, length: l2)!
			let res = collation(s1, s2)
			return Int32(res.rawValue)
		}
		try name.withCUTF8 {
			try check(sqlite3_create_collation_v2(connection, $0, SQLITE_UTF8, context.toC, cmp, { CollationContext.releaseC($0) }))
		}
	}

	public func unregister(collationName: String) throws {
		try collationName.withCUTF8 {
			try check(sqlite3_create_collation_v2(connection, $0, SQLITE_UTF8, nil, nil, nil))
		}
	}

	private static func value(from parameters: UnsafeMutablePointer<OpaquePointer?>, index: Int32) -> Data {
		let param = parameters[Int(index)]
		switch sqlite3_value_type(param) {
			case SQLITE_TEXT:
				let length = sqlite3_value_bytes(param)
				let bytes = sqlite3_value_text(param)!
				return .text(String(cUTF8: bytes, length: length)!)
			case SQLITE_BLOB:
				let length = sqlite3_value_bytes(param)
				let bytes = sqlite3_value_blob(param)
				return .blob(Foundation.Data(bytes: UnsafePointer<UInt8>(OpaquePointer(bytes)!), count: Int(length)))
			case SQLITE_INTEGER:
				return .integer(sqlite3_value_int64(param))
			case SQLITE_FLOAT:
				return .float(sqlite3_value_double(param))
			case SQLITE_NULL:
				return .null
			default:
				fatalError("Unknown Value Type")
		}
	}

	private static func set(_ value: Data, context: OpaquePointer?) {
		switch value {
			case .text(let string):
				string.withCUTF8 { sqlite3_result_text64(context, $0, $1, TRANSIENT, UInt8(SQLITE_UTF8)) }
			case .blob(let data):
				data.withUnsafeBytes { sqlite3_result_blob64(context, $0, $1, TRANSIENT) }
			case .float(let double):
				sqlite3_result_double(context, double)
			case .integer(let int):
				sqlite3_result_int64(context, int)
			case .null:
				sqlite3_result_null(context)
		}
	}

	private static func perform(inContext: OpaquePointer?, applicationFunction: () throws -> Void) {
		do {
			try applicationFunction()
		} catch Error.other(let message, let code) {
			try? message?.withShortCUTF8 { sqlite3_result_error(inContext, $0, $1) }
			sqlite3_result_error_code(inContext, code.clampedTo32Bit)
		} catch Error.error(let message) {
			try? message?.withShortCUTF8 { sqlite3_result_error(inContext, $0, $1) }
			sqlite3_result_error_code(inContext, SQLITE_ERROR)
		} catch Error.sqliteSwiftError(let message) {
			try? message.withShortCUTF8 { sqlite3_result_error(inContext, $0, $1) }
			sqlite3_result_error_code(inContext, SQLITE_ERROR)
		} catch _ {
			sqlite3_result_error_code(inContext, SQLITE_ERROR)
		}
	}
}

public extension SQLite {
	private typealias FactoryContext = ContextWrapper<([String]) throws -> ((FTS5TokenizeFlags, String) throws -> [(FTS5TokenFlags, String, Range<String.Index>)])>
	private typealias TokenizerContext = ContextWrapper<(FTS5TokenizeFlags, String) throws -> [(FTS5TokenFlags, String, Range<String.Index>)]>

	public func registerFTS5Tokenizer(named name: String, factory: @escaping ([String]) throws -> ((FTS5TokenizeFlags, String) throws -> [(FTS5TokenFlags, String, Range<String.Index>)])) throws {
		var api: UnsafeMutablePointer<fts5_api>!
		guard let stmt = fts5APIStmt else {
			throw Error.sqliteSwiftError("failed to prepare statement")
		}
		try stmt.bind(pointer: &api, ofType: sqlite3_fts5_api_pointer_type, to: 1)
		try stmt.execute()
		let result = name.withCUTF8 { cUTF8 in
			api.pointee.xCreateTokenizer(api, cUTF8, FactoryContext(data: factory).toC, &SQLite.tokenizer, { FactoryContext.releaseC($0) })
		}
		try check(result)
	}

	private static var tokenizer = fts5_tokenizer(xCreate: { (context, argv, argc, tokenizerOut) -> Int32 in
		var args = [String]()
		for i in 0 ..< Int(argc) {
			args.append(String(cUTF8: argv![i]!)!)
		}
		do {
			let tokenizer = try FactoryContext.fromC(context)!.data(args)
			let tokenizerContext = TokenizerContext(data: tokenizer)
			tokenizerOut!.pointee = OpaquePointer(tokenizerContext.toC)
			return SQLITE_OK
		} catch {
			return SQLITE_ERROR
		}
	}, xDelete: {
		TokenizerContext.releaseC(UnsafeMutableRawPointer($0))
	}, xTokenize: { tokenizerCtx, ctx, flags, cStr, len, callback -> Int32 in
		let tokenizer = TokenizerContext.fromC(UnsafeMutableRawPointer(tokenizerCtx!)).data
		let str = String(cUTF8: cStr!, length: len)!
		do {
			let tokens = try tokenizer(FTS5TokenizeFlags(rawValue: flags), str)
			for (flags, token, range) in tokens {
				let utf8 = str.utf8
				let startIndex = range.lowerBound.samePosition(in: utf8)!
				let endIndex = range.upperBound.samePosition(in: utf8)!
				let start = utf8[utf8.startIndex ..< startIndex].count
				let end = utf8[utf8.startIndex ..< endIndex].count
				guard let end32 = Int32(exactly: end), let start32 = Int32(exactly: start) else {
					return SQLITE_ERROR
				}
				let result = try token.withShortCUTF8 { cUTF8, len in
					callback!(ctx, flags.rawValue, cUTF8, len, start32, end32)
				}
				guard result == SQLITE_OK else {
					return result
				}
			}
			return SQLITE_OK
		} catch {
			return SQLITE_ERROR
		}
	})

	public struct FTS5TokenizeFlags: OptionSet {
		public let rawValue: Int32

		public init(rawValue value: Int32) {
			rawValue = value
		}

		public static let query		= FTS5TokenizeFlags(rawValue: FTS5_TOKENIZE_QUERY)
		public static let prefix	= FTS5TokenizeFlags(rawValue: FTS5_TOKENIZE_PREFIX)
		public static let document	= FTS5TokenizeFlags(rawValue: FTS5_TOKENIZE_DOCUMENT)
		public static let aux		= FTS5TokenizeFlags(rawValue: FTS5_TOKENIZE_AUX)
	}

	public struct FTS5TokenFlags: OptionSet {
		public let rawValue: Int32

		public init(rawValue value: Int32) {
			rawValue = value
		}

		public static let colocated	= FTS5TokenFlags(rawValue: FTS5_TOKEN_COLOCATED)
	}
}

// Internals
private class ContextWrapper<T> {
	var data: T

	init(data: T) {
		self.data = data
	}

	convenience init?(data: T?) {
		guard let data = data else {
			return nil
		}
		self.init(data: data)
	}

	var toC: UnsafeMutableRawPointer {
		return Unmanaged.passRetained(self).toOpaque()
	}

	class func fromC(_ ptr: UnsafeMutableRawPointer?) -> ContextWrapper? {
		guard let ptr = ptr else {
			return nil
		}
		return fromC(ptr)
	}

	class func fromC(_ ptr: UnsafeMutableRawPointer) -> ContextWrapper {
		return Unmanaged<ContextWrapper>.fromOpaque(ptr).takeUnretainedValue()
	}

	class func releaseC(_ ptr: UnsafeMutableRawPointer?) {
		if let ptr = ptr {
			Unmanaged<ContextWrapper>.fromOpaque(ptr).release()
		}
	}
}
