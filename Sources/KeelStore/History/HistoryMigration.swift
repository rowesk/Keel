import Foundation

extension KeelStore {
    static func createHistorySchema(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE history_branches (
                id TEXT PRIMARY KEY NOT NULL,
                browsing_session_id TEXT NOT NULL,
                kind TEXT NOT NULL CHECK (kind IN ('root', 'detour')),
                created_at REAL NOT NULL,
                FOREIGN KEY (browsing_session_id) REFERENCES browsing_sessions(id) ON DELETE RESTRICT
            )
            """)
        try database.execute("CREATE INDEX history_branches_session_index ON history_branches(browsing_session_id)")
        try database.execute("""
            CREATE TABLE history_hostname_groups (
                id TEXT PRIMARY KEY NOT NULL,
                browsing_session_id TEXT NOT NULL,
                branch_id TEXT NOT NULL,
                hostname TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                first_visited_at REAL NOT NULL,
                last_visited_at REAL NOT NULL,
                UNIQUE(branch_id, ordinal),
                FOREIGN KEY (browsing_session_id) REFERENCES browsing_sessions(id) ON DELETE RESTRICT,
                FOREIGN KEY (branch_id) REFERENCES history_branches(id) ON DELETE CASCADE
            )
            """)
        try database.execute("CREATE INDEX history_hostname_groups_branch_index ON history_hostname_groups(branch_id, ordinal)")
        try database.execute("""
            CREATE TABLE history_urls (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                canonical_url TEXT UNIQUE NOT NULL,
                display_url TEXT NOT NULL,
                origin TEXT NOT NULL,
                hostname TEXT NOT NULL,
                host_folded TEXT NOT NULL,
                path_folded TEXT NOT NULL,
                title_folded TEXT NOT NULL,
                title TEXT,
                favicon_reference_key TEXT,
                visit_count INTEGER NOT NULL,
                typed_count INTEGER NOT NULL,
                last_visited_at REAL NOT NULL,
                last_typed_at REAL
            )
            """)
        try database.execute("CREATE INDEX history_urls_canonical_index ON history_urls(canonical_url)")
        try database.execute("CREATE INDEX history_urls_host_index ON history_urls(host_folded)")
        try database.execute("CREATE INDEX history_urls_last_visited_index ON history_urls(last_visited_at DESC)")
        try database.execute("""
            CREATE TABLE history_url_terms (
                history_url_id INTEGER NOT NULL,
                token TEXT NOT NULL,
                PRIMARY KEY (history_url_id, token),
                FOREIGN KEY (history_url_id) REFERENCES history_urls(id) ON DELETE CASCADE
            )
            """)
        try database.execute("CREATE INDEX history_url_terms_token_index ON history_url_terms(token)")
        try database.execute("CREATE TABLE history_visit_sequence (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), next_sequence INTEGER NOT NULL)")
        try database.execute("""
            CREATE TABLE history_visits (
                id TEXT PRIMARY KEY NOT NULL,
                sequence INTEGER UNIQUE NOT NULL,
                history_url_id INTEGER NOT NULL,
                browsing_session_id TEXT NOT NULL,
                branch_id TEXT NOT NULL,
                hostname_group_id TEXT NOT NULL,
                visited_at REAL NOT NULL,
                navigation_kind TEXT NOT NULL,
                visit_source TEXT NOT NULL,
                was_typed INTEGER NOT NULL,
                typed_at REAL,
                title_at_visit TEXT,
                favicon_reference_key TEXT,
                FOREIGN KEY (history_url_id) REFERENCES history_urls(id) ON DELETE RESTRICT,
                FOREIGN KEY (browsing_session_id) REFERENCES browsing_sessions(id) ON DELETE RESTRICT,
                FOREIGN KEY (branch_id) REFERENCES history_branches(id) ON DELETE RESTRICT,
                FOREIGN KEY (hostname_group_id) REFERENCES history_hostname_groups(id) ON DELETE RESTRICT
            )
            """)
        try database.execute("CREATE INDEX history_visits_session_index ON history_visits(browsing_session_id, visited_at, sequence)")
        try database.execute("CREATE INDEX history_visits_branch_index ON history_visits(branch_id, visited_at, sequence)")
        try database.execute("CREATE INDEX history_visits_url_index ON history_visits(history_url_id)")
        try database.execute("CREATE INDEX history_visits_group_index ON history_visits(hostname_group_id)")
        try database.execute("""
            CREATE TABLE address_choice_history (
                input_prefix_folded TEXT NOT NULL,
                history_url_id INTEGER NOT NULL,
                use_count INTEGER NOT NULL,
                last_used_at REAL NOT NULL,
                PRIMARY KEY (input_prefix_folded, history_url_id),
                FOREIGN KEY (history_url_id) REFERENCES history_urls(id) ON DELETE CASCADE
            )
            """)
        try database.execute("CREATE INDEX address_choice_history_url_index ON address_choice_history(history_url_id)")
        try database.execute("INSERT INTO history_visit_sequence (singleton, next_sequence) VALUES (1, 0)")
    }
}
