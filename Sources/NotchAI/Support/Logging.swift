import os

enum Log {
    static let app = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "app")
    static let island = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "island")
    static let capture = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "capture")
    static let chat = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "chat")
    static let ai = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "ai")
    static let browser = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "browser")
    static let settings = Logger(subsystem: "com.aadithkannoth.NotchAI", category: "settings")
}
