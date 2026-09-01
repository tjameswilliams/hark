//! End-to-end knowledge-layer tests. The main test downloads the real
//! BGESmallENV15 model (~34 MB) into a shared temp cache on first run and
//! exercises indexing + semantic search for real — deliberately not ignored.

use hark_core::ffi::{HarkStore, MeetingSegmentInput};

/// Model cache shared across test runs so the download happens once per boot.
fn model_cache_dir() -> String {
    let dir = std::env::temp_dir().join("hark-test-fastembed-cache");
    std::fs::create_dir_all(&dir).unwrap();
    dir.to_string_lossy().into_owned()
}

fn fresh_store(name: &str) -> (std::sync::Arc<HarkStore>, std::path::PathBuf) {
    let dir = std::env::temp_dir().join(format!("hark-e2e-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("test.sqlite");
    let _ = std::fs::remove_file(&path);
    let _ = std::fs::remove_file(dir.join("test.sqlite-wal"));
    let _ = std::fs::remove_file(dir.join("test.sqlite-shm"));
    (HarkStore::open(path.to_string_lossy().into_owned()).unwrap(), path)
}

fn record_distractors(store: &HarkStore) {
    let texts = [
        "Quarterly budget review is scheduled for Thursday; finance wants the spreadsheet \
         updated with the new vendor invoices before then.",
        "The database migration deployed cleanly to staging last night and the replication \
         lag stayed under two seconds the whole time.",
        "Grandma's pasta recipe calls for fresh basil, garlic, and a very slow tomato \
         reduction, at least ninety minutes on low heat.",
        "Remember to renew the passport and book the flights for the Lisbon conference \
         before prices go up next month.",
    ];
    for (i, t) in texts.iter().enumerate() {
        store
            .record_dictation(
                t.to_string(),
                None,
                None,
                format!("2026-08-30T0{i}:00:00Z"),
                format!("2026-08-30T0{i}:00:05Z"),
                5000,
            )
            .unwrap();
    }
}

/// Chunking + embedding + hybrid search against the real model. Asserts a
/// purely semantic query ("bird of prey" — zero keyword overlap) ranks the
/// falconry chunk in the top 3, and that project assignment syncs the vec
/// table's aux project_id and is honored by search filtering.
#[test]
fn index_and_semantic_search_end_to_end() {
    let (store, db_path) = fresh_store("semantic");
    let cache = model_cache_dir();

    record_distractors(&store);

    // A meeting with two long speaker turns → two chunks, with speakers.
    let falconry = "The hawk stooped on the lure exactly the way the manual described, wings \
        tucked, dropping like a stone until the very last moment. The falconer whistled twice \
        and swung the lure low across the grass, and the whole class went quiet watching the \
        approach. Afterwards we discussed jesses, telemetry mounts, and how much weight the \
        bird should be flown at during the moult, since an overweight bird simply will not \
        commit to the stoop at all.";
    let budget = "Moving on to the numbers, the quarterly spend is tracking eight percent over \
        plan, mostly because of the cloud bill and the contractor renewals that landed in the \
        same month. If we push the laptop refresh to next quarter and renegotiate the support \
        tier we should land within two percent of the original envelope, which finance has \
        already said they can live with, provided we flag it in the board deck.";
    let meeting_id = store
        .record_meeting(
            Some("Field trip debrief".into()),
            "2026-08-31T15:00:00Z".into(),
            "2026-08-31T15:30:00Z".into(),
            None,
            vec![
                MeetingSegmentInput {
                    speaker_label: "SPEAKER_00".into(),
                    t_start_ms: 0,
                    t_end_ms: 60_000,
                    text: falconry.into(),
                    confidence: Some(0.9),
                },
                MeetingSegmentInput {
                    speaker_label: "SPEAKER_01".into(),
                    t_start_ms: 61_000,
                    t_end_ms: 120_000,
                    text: budget.into(),
                    confidence: Some(0.9),
                },
            ],
        )
        .unwrap();

    // Index everything: 4 dictations + 1 meeting = 5 sessions processed.
    let processed = store.index_pending(cache.clone()).unwrap();
    assert_eq!(processed, 5, "all sessions should be chunked+embedded");
    // Idempotent: nothing left to do.
    assert_eq!(store.index_pending(cache.clone()).unwrap(), 0);

    // Semantic query with no keyword overlap with the falconry chunk.
    let hits = store
        .search("bird of prey".into(), None, None, 5, cache.clone())
        .unwrap();
    assert!(!hits.is_empty(), "semantic search returned nothing");
    let top3 = &hits[..hits.len().min(3)];
    println!("semantic query 'bird of prey' top hits:");
    for h in &hits {
        println!(
            "  session={} chunk={} score={:.5} speaker={:?} snippet={:?}",
            h.session_id, h.chunk_id, h.score, h.speaker, h.snippet
        );
    }
    // The falconry chunk is the meeting chunk starting at t=0 (SPEAKER_00's
    // turn — the snippet may center on "bird…", not "hawk…").
    let falconry_hit = top3
        .iter()
        .find(|h| h.session_id == meeting_id && h.t_start_ms == 0)
        .unwrap_or_else(|| panic!("falconry chunk not in top-3 for 'bird of prey': {top3:#?}"));
    assert_eq!(falconry_hit.kind, "meeting");
    assert_eq!(falconry_hit.speaker.as_deref(), Some("SPEAKER_00"));
    assert_eq!(falconry_hit.title.as_deref(), Some("Field trip debrief"));
    assert!(falconry_hit.score > 0.0);

    // Hybrid: a keyword query still works and cites the right session.
    let kw = store
        .search("pasta recipe basil".into(), None, None, 5, cache.clone())
        .unwrap();
    assert!(kw[0].snippet.contains("basil"), "keyword leg broken: {kw:#?}");
    assert_eq!(kw[0].kind, "dictation");

    // Kind filter.
    let meetings_only = store
        .search("quarterly budget".into(), None, Some("meeting".into()), 5, cache.clone())
        .unwrap();
    assert!(!meetings_only.is_empty());
    assert!(meetings_only.iter().all(|h| h.kind == "meeting"));

    // -- Projects: assignment syncs aux project_id and filters search. ------
    let project_id = store
        .create_project("Falconry".into(), Some("hawk stuff".into()))
        .unwrap();
    store.assign_session(meeting_id, Some(project_id)).unwrap();

    let projects = store.list_projects().unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0].name, "Falconry");
    assert_eq!(projects[0].session_count, 1);

    // Aux column really updated (read through a second connection).
    let db = hark_core::Db::open(&db_path).unwrap();
    let (assigned, unassigned): (i64, i64) = db
        .conn()
        .query_row(
            "SELECT
                (SELECT count(*) FROM chunk_embeddings e
                 JOIN chunks c ON c.id = e.rowid
                 WHERE c.session_id = ?1 AND e.project_id = ?2),
                (SELECT count(*) FROM chunk_embeddings e
                 JOIN chunks c ON c.id = e.rowid
                 WHERE c.session_id != ?1 AND e.project_id = 0)",
            rusqlite::params![meeting_id, project_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(assigned, 2, "both meeting chunks should carry the project id");
    assert_eq!(unassigned, 4, "dictation chunks stay unassigned (0)");

    // Search honors the project filter (post-filter over the KNN/FTS union).
    let in_project = store
        .search("bird of prey".into(), Some(project_id), None, 5, cache.clone())
        .unwrap();
    assert!(!in_project.is_empty());
    assert!(in_project.iter().all(|h| h.session_id == meeting_id));

    // A project with no sessions matches nothing.
    let empty_project = store.create_project("Empty".into(), None).unwrap();
    let none = store
        .search("bird of prey".into(), Some(empty_project), None, 5, cache.clone())
        .unwrap();
    assert!(none.is_empty(), "empty-project filter leaked hits: {none:#?}");

    // Un-assign puts the aux column back to 0.
    store.assign_session(meeting_id, None).unwrap();
    let back: i64 = db
        .conn()
        .query_row(
            "SELECT count(*) FROM chunk_embeddings WHERE project_id = 0",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(back, 6);
}

/// Offline / degraded behavior: with an unusable model cache dir, indexing
/// still lands chunks + FTS (then errors on the embed step), and search
/// degrades to keyword-only results without panicking or erroring.
#[test]
fn fts_only_fallback_without_model() {
    let (store, _path) = fresh_store("fallback");
    let bogus = "/dev/null/definitely-not-a-model-dir".to_string();

    // Search before anything is indexed: no results, no panic, no error.
    let empty = store
        .search("hawk".into(), None, None, 10, bogus.clone())
        .unwrap();
    assert!(empty.is_empty());

    store
        .record_dictation(
            "the hawk stooped on the lure during training".into(),
            None,
            None,
            "2026-08-31T12:00:00Z".into(),
            "2026-08-31T12:00:03Z".into(),
            3000,
        )
        .unwrap();
    record_distractors(&store);

    // Embedding model unavailable → index_pending errors, but the chunking
    // pass has already committed (FTS is live).
    let err = store.index_pending(bogus.clone());
    assert!(err.is_err(), "bogus model dir must fail the embed pass");

    // Keyword search now works, model-free.
    let hits = store
        .search("hawk lure".into(), None, None, 10, bogus.clone())
        .unwrap();
    assert_eq!(hits.len(), 1, "FTS-only fallback broken: {hits:#?}");
    assert!(hits[0].snippet.contains("hawk"));
    assert_eq!(hits[0].kind, "dictation");

    // Malformed / operator-laden queries must not error.
    for q in ["AND ((", "\"unbalanced", "NEAR(", "hawk* OR"] {
        let r = store.search(q.into(), None, None, 10, bogus.clone());
        assert!(r.is_ok(), "query {q:?} errored: {r:?}");
    }

    // A later index_pending with a working dir would embed the already-stored
    // chunks (pass B); verify they are queued, i.e. chunks exist sans vectors.
    let more = store.search("basil".into(), None, None, 10, bogus).unwrap();
    assert_eq!(more.len(), 1);
}
