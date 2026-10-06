//! Cross-meeting speaker identity.
//!
//! Every diarized label in a meeting carries a voiceprint (a 256-d speaker
//! embedding averaged over that label's speech). A *person* is a `speakers`
//! row with `named = 1`; their voiceprints are the ones on every meeting
//! label the user has confirmed as them. A new meeting's labels are matched
//! against those by cosine distance.
//!
//! Thresholds come from measurements on real recordings (the voiceprint
//! spike, 15 meetings): the same person in different meetings sat 0.02–0.27
//! apart, different people from about 0.45 up, with speakers under 30 s of
//! talk time excluded as too noisy to trust.

use rusqlite::{Connection, OptionalExtension};

use crate::ffi::HarkError;

/// At or below this distance a label is assigned to the known person outright.
pub const AUTO_MATCH_DISTANCE: f32 = 0.30;
/// Up to this distance the person is offered as a suggestion, never applied.
pub const SUGGEST_DISTANCE: f32 = 0.45;
/// Talk time a label needs before its voiceprint can auto-match, or count
/// towards a person once confirmed.
pub const MIN_ENROLL_MS: i64 = 30_000;
/// Below `MIN_ENROLL_MS` but above this, a close match is still worth
/// suggesting; shorter than this and the voiceprint is ignored.
pub const MIN_SUGGEST_MS: i64 = 10_000;

pub fn embedding_from_blob(blob: &[u8]) -> Vec<f32> {
    blob.chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect()
}

/// L2-normalized copy; None for an empty or zero vector.
pub fn normalized(v: &[f32]) -> Option<Vec<f32>> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if v.is_empty() || !norm.is_finite() || norm <= f32::EPSILON {
        return None;
    }
    Some(v.iter().map(|x| x / norm).collect())
}

/// Cosine distance between two normalized vectors: 0 identical, 1 unrelated.
pub fn distance(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return f32::INFINITY;
    }
    1.0 - a.iter().zip(b).map(|(x, y)| x * y).sum::<f32>()
}

/// A named person and every confirmed voiceprint of theirs.
pub struct Person {
    pub id: i64,
    pub name: String,
    prints: Vec<Vec<f32>>,
    mean: Option<Vec<f32>>,
}

impl Person {
    /// Distance from `voiceprint` to this person: the closer of their average
    /// voice and their single closest meeting. The average is the steadier
    /// estimate; the per-meeting minimum keeps someone recognizable when one
    /// of their recordings sounds unlike the rest (another microphone, say)
    /// and would otherwise be averaged away.
    pub fn distance_to(&self, voiceprint: &[f32]) -> f32 {
        self.prints
            .iter()
            .chain(self.mean.iter())
            .map(|print| distance(print, voiceprint))
            .fold(f32::INFINITY, f32::min)
    }
}

/// Everyone with at least one usable confirmed voiceprint.
pub fn load_people(conn: &Connection) -> Result<Vec<Person>, HarkError> {
    let mut stmt = conn.prepare(
        "SELECT sp.id, sp.display_name, ss.voiceprint
         FROM session_speakers ss
         JOIN speakers sp ON sp.id = ss.speaker_id
         WHERE sp.named = 1 AND ss.confirmed = 1
           AND ss.voiceprint IS NOT NULL AND ss.talk_ms >= ?1
         ORDER BY sp.id",
    )?;
    let rows = stmt.query_map([MIN_ENROLL_MS], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, Option<String>>(1)?,
            row.get::<_, Vec<u8>>(2)?,
        ))
    })?;
    let mut people: Vec<Person> = Vec::new();
    for row in rows {
        let (id, name, blob) = row?;
        let Some(print) = normalized(&embedding_from_blob(&blob)) else {
            continue;
        };
        match people.last_mut() {
            Some(person) if person.id == id => person.prints.push(print),
            _ => people.push(Person {
                id,
                name: name.unwrap_or_default(),
                prints: vec![print],
                mean: None,
            }),
        }
    }
    for person in &mut people {
        let dims = person.prints[0].len();
        let mut sum = vec![0.0f32; dims];
        for print in person.prints.iter().filter(|p| p.len() == dims) {
            for (total, x) in sum.iter_mut().zip(print) {
                *total += x;
            }
        }
        person.mean = normalized(&sum);
    }
    Ok(people)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Verdict {
    /// Assign the label to this person.
    Match { speaker_id: i64, distance: f32 },
    /// Offer this person, but leave the label unnamed.
    Suggest { speaker_id: i64, distance: f32 },
    Unknown,
}

/// Who, if anyone, a meeting label's voiceprint belongs to.
pub fn identify(people: &[Person], voiceprint: &[f32], talk_ms: i64) -> Verdict {
    if talk_ms < MIN_SUGGEST_MS {
        return Verdict::Unknown;
    }
    let Some(voiceprint) = normalized(voiceprint) else {
        return Verdict::Unknown;
    };
    let nearest = people
        .iter()
        .map(|person| (person.id, person.distance_to(&voiceprint)))
        .min_by(|a, b| a.1.total_cmp(&b.1));
    match nearest {
        Some((speaker_id, distance)) if distance <= AUTO_MATCH_DISTANCE => {
            if talk_ms >= MIN_ENROLL_MS {
                Verdict::Match { speaker_id, distance }
            } else {
                Verdict::Suggest { speaker_id, distance }
            }
        }
        Some((speaker_id, distance)) if distance <= SUGGEST_DISTANCE && talk_ms >= MIN_ENROLL_MS => {
            Verdict::Suggest { speaker_id, distance }
        }
        _ => Verdict::Unknown,
    }
}

/// The named person called `name` (case-insensitive), created if new.
fn person_named(conn: &Connection, name: &str) -> Result<i64, HarkError> {
    let existing: Option<i64> = conn
        .query_row(
            "SELECT id FROM speakers WHERE named = 1 AND display_name = ?1 COLLATE NOCASE
             ORDER BY id LIMIT 1",
            [name],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(id) = existing {
        return Ok(id);
    }
    conn.execute(
        "INSERT INTO speakers (display_name, named) VALUES (?1, 1)",
        [name],
    )?;
    Ok(conn.last_insert_rowid())
}

/// Points one meeting label (and its segments) at `speaker_id`.
fn repoint(conn: &Connection, session_id: i64, label: &str, speaker_id: i64) -> Result<(), HarkError> {
    conn.execute(
        "UPDATE session_speakers SET speaker_id = ?1 WHERE session_id = ?2 AND label = ?3",
        rusqlite::params![speaker_id, session_id, label],
    )?;
    conn.execute(
        "UPDATE segments SET speaker_id = ?1 WHERE session_id = ?2 AND speaker_label = ?3",
        rusqlite::params![speaker_id, session_id, label],
    )?;
    Ok(())
}

/// Removes a speaker row no meeting refers to any more: a per-meeting
/// placeholder that was just named, or a person whose only label was renamed.
fn delete_if_unused(conn: &Connection, speaker_id: i64) -> Result<(), HarkError> {
    conn.execute(
        "DELETE FROM speakers WHERE id = ?1
           AND NOT EXISTS (SELECT 1 FROM session_speakers WHERE speaker_id = ?1)",
        [speaker_id],
    )?;
    Ok(())
}

/// Names one meeting label (`name` = Some) or returns it to an unnamed
/// placeholder (None / blank). Naming is a confirmation: from then on the
/// label's voiceprint counts towards that person. Returns whether the
/// label's speaker changed.
pub fn assign_label(
    conn: &Connection,
    session_id: i64,
    label: &str,
    name: Option<&str>,
) -> Result<bool, HarkError> {
    let (current, currently_named): (i64, bool) = conn
        .query_row(
            "SELECT ss.speaker_id, sp.named FROM session_speakers ss
             JOIN speakers sp ON sp.id = ss.speaker_id
             WHERE ss.session_id = ?1 AND ss.label = ?2",
            rusqlite::params![session_id, label],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?
        .ok_or_else(|| {
            HarkError::Failure(format!("meeting #{session_id} has no speaker {label}"))
        })?;

    let name = name.map(str::trim).filter(|n| !n.is_empty());
    let target = match name {
        Some(name) => person_named(conn, name)?,
        None if currently_named => {
            conn.execute(
                "INSERT INTO speakers (display_name, named) VALUES (?1, 0)",
                [label],
            )?;
            conn.last_insert_rowid()
        }
        None => current,
    };
    if target != current {
        repoint(conn, session_id, label, target)?;
        delete_if_unused(conn, current)?;
    }
    conn.execute(
        "UPDATE session_speakers SET confirmed = ?1 WHERE session_id = ?2 AND label = ?3",
        rusqlite::params![name.is_some(), session_id, label],
    )?;
    Ok(target != current)
}

/// Sessions in which `speaker_id` appears.
fn sessions_of(conn: &Connection, speaker_id: i64) -> Result<Vec<i64>, HarkError> {
    let mut stmt =
        conn.prepare("SELECT DISTINCT session_id FROM session_speakers WHERE speaker_id = ?1")?;
    let rows = stmt.query_map([speaker_id], |row| row.get(0))?;
    Ok(rows.collect::<Result<Vec<i64>, _>>()?)
}

/// Renames a person. Renaming onto another person's name merges the two.
/// Returns the sessions whose transcripts changed.
pub fn rename_person(conn: &Connection, speaker_id: i64, name: &str) -> Result<Vec<i64>, HarkError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(HarkError::Failure("a person needs a name".into()));
    }
    let sessions = sessions_of(conn, speaker_id)?;
    let other: Option<i64> = conn
        .query_row(
            "SELECT id FROM speakers
             WHERE named = 1 AND id != ?1 AND display_name = ?2 COLLATE NOCASE",
            rusqlite::params![speaker_id, name],
            |row| row.get(0),
        )
        .optional()?;
    match other {
        Some(other) => {
            conn.execute(
                "UPDATE session_speakers SET speaker_id = ?1 WHERE speaker_id = ?2",
                [other, speaker_id],
            )?;
            conn.execute(
                "UPDATE segments SET speaker_id = ?1 WHERE speaker_id = ?2",
                [other, speaker_id],
            )?;
            conn.execute("DELETE FROM speakers WHERE id = ?1", [speaker_id])?;
        }
        None => {
            let changed = conn.execute(
                "UPDATE speakers SET display_name = ?1 WHERE id = ?2 AND named = 1",
                rusqlite::params![name, speaker_id],
            )?;
            if changed == 0 {
                return Err(HarkError::Failure(format!("person #{speaker_id} not found")));
            }
        }
    }
    Ok(sessions)
}

/// Forgets a person: their name comes off every meeting and their
/// voiceprints are erased, so they can never be matched again. The
/// transcripts stay, attributed to the original per-meeting labels.
/// Returns the sessions whose transcripts changed.
pub fn forget_person(conn: &Connection, speaker_id: i64) -> Result<Vec<i64>, HarkError> {
    let labels: Vec<(i64, String)> = {
        let mut stmt = conn
            .prepare("SELECT session_id, label FROM session_speakers WHERE speaker_id = ?1")?;
        let rows = stmt.query_map([speaker_id], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    for (session_id, label) in &labels {
        conn.execute(
            "INSERT INTO speakers (display_name, named) VALUES (?1, 0)",
            [label],
        )?;
        repoint(conn, *session_id, label, conn.last_insert_rowid())?;
        conn.execute(
            "UPDATE session_speakers
             SET voiceprint = NULL, confirmed = 0, match_distance = NULL
             WHERE session_id = ?1 AND label = ?2",
            rusqlite::params![session_id, label],
        )?;
    }
    conn.execute(
        "UPDATE session_speakers SET suggested_speaker_id = NULL, match_distance = NULL
         WHERE suggested_speaker_id = ?1",
        [speaker_id],
    )?;
    conn.execute("DELETE FROM speakers WHERE id = ?1 AND named = 1", [speaker_id])?;
    let mut sessions: Vec<i64> = labels.into_iter().map(|(session_id, _)| session_id).collect();
    sessions.dedup();
    Ok(sessions)
}

/// Drops a session's chunks so the next `index_pending` rebuilds them. Chunk
/// boundaries and the embedded text both depend on who said what, so any
/// change of speaker names makes the old index stale.
pub fn invalidate_index(conn: &Connection, session_id: i64) -> Result<(), HarkError> {
    conn.execute("DELETE FROM chunks WHERE session_id = ?1", [session_id])?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unit(dims: usize, hot: usize) -> Vec<f32> {
        let mut v = vec![0.0; dims];
        v[hot] = 1.0;
        v
    }

    fn person(id: i64, prints: Vec<Vec<f32>>) -> Person {
        let mut sum = vec![0.0f32; prints[0].len()];
        for print in &prints {
            for (total, x) in sum.iter_mut().zip(print) {
                *total += x;
            }
        }
        Person {
            id,
            name: format!("P{id}"),
            mean: normalized(&sum),
            prints,
        }
    }

    /// A vector `d` away (cosine distance) from unit(_, 0), leaning to axis 1.
    fn near_axis0(dims: usize, d: f32) -> Vec<f32> {
        let cos = 1.0 - d;
        let mut v = vec![0.0; dims];
        v[0] = cos;
        v[1] = (1.0 - cos * cos).sqrt();
        v
    }

    #[test]
    fn identify_applies_the_measured_tiers() {
        let people = vec![person(1, vec![unit(8, 0)]), person(2, vec![unit(8, 3)])];
        assert!(matches!(
            identify(&people, &near_axis0(8, 0.15), 60_000),
            Verdict::Match { speaker_id: 1, .. }
        ));
        assert!(matches!(
            identify(&people, &near_axis0(8, 0.38), 60_000),
            Verdict::Suggest { speaker_id: 1, .. }
        ));
        assert_eq!(identify(&people, &near_axis0(8, 0.6), 60_000), Verdict::Unknown);
        // A close voice with little speech is only ever a suggestion…
        assert!(matches!(
            identify(&people, &near_axis0(8, 0.15), 15_000),
            Verdict::Suggest { speaker_id: 1, .. }
        ));
        // …and with almost none it is ignored.
        assert_eq!(identify(&people, &near_axis0(8, 0.15), 4_000), Verdict::Unknown);
        assert_eq!(identify(&[], &unit(8, 0), 60_000), Verdict::Unknown);
    }

    #[test]
    fn a_person_stays_recognizable_from_an_unusual_recording() {
        // Two meetings on one microphone, one on a very different one: the
        // average drifts, the lone voiceprint still matches itself.
        let odd = unit(8, 5);
        let p = person(1, vec![unit(8, 0), near_axis0(8, 0.05), odd.clone()]);
        assert!(p.distance_to(&odd) < 0.01);
        assert!(p.distance_to(&near_axis0(8, 0.1)) < AUTO_MATCH_DISTANCE);
    }

    #[test]
    fn unnormalized_and_degenerate_voiceprints() {
        let people = vec![person(1, vec![unit(8, 0)])];
        let loud: Vec<f32> = near_axis0(8, 0.1).iter().map(|x| x * 40.0).collect();
        assert!(matches!(identify(&people, &loud, 60_000), Verdict::Match { .. }));
        assert_eq!(identify(&people, &[0.0; 8], 60_000), Verdict::Unknown);
        assert_eq!(identify(&people, &[1.0; 4], 60_000), Verdict::Unknown);
    }
}
