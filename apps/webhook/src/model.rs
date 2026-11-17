//! Everything that does not need the watch's `Api`: the slot list, its NAND blob and the `h1` wire format.
//! Shared by the app and the host tests.

/// Shortcuts the watch shows. Six rows fit the 466 px panel without scrolling.
pub const SLOTS: usize = 6;
/// A name is cut at 23 bytes on the phone side too; 23 + the length byte stays inside a 128 B message.
pub const NAME_MAX: usize = 23;
const BLOB_HEAD: [u8; 2] = *b"h1";
const BLOB_VERSION: u8 = 1;

#[derive(Clone, Copy)]
pub struct Slot {
    buf: [u8; NAME_MAX],
    len: u8,
}

impl Slot {
    /// `false` when the name is unchanged, so a repeated list does not redraw or rewrite NAND.
    fn set(&mut self, name: &[u8]) -> bool {
        // A name is read back as `&str`: cut on a char boundary, and drop invalid UTF-8 from the phone too.
        let mut n = name.len().min(NAME_MAX);
        while n > 0 && core::str::from_utf8(&name[..n]).is_err() {
            n -= 1;
        }
        if self.len as usize == n && self.buf[..n] == name[..n] {
            return false;
        }
        self.buf[..n].copy_from_slice(&name[..n]);
        self.len = n as u8;
        true
    }

    pub fn name(&self) -> &str {
        core::str::from_utf8(&self.buf[..self.len as usize]).unwrap_or("?")
    }
}

#[derive(Clone, Copy)]
pub struct Slots {
    items: [Slot; SLOTS],
}

impl Default for Slots {
    fn default() -> Self {
        let mut slots = Slots { items: [Slot { buf: [0; NAME_MAX], len: 0 }; SLOTS] };
        for (i, slot) in slots.items.iter_mut().enumerate() {
            let mut line = [0u8; NAME_MAX];
            let head = b"Shortcut ";
            line[..head.len()].copy_from_slice(head);
            line[head.len()] = b'1' + i as u8;
            slot.set(&line[..head.len() + 1]);
        }
        slots
    }
}

impl Slots {
    pub fn get(&self, i: usize) -> &str {
        self.items.get(i).map_or("", |s| s.name())
    }

    /// `false` for an index off the list, an empty name, or a name that did not change.
    pub fn set(&mut self, i: usize, name: &[u8]) -> bool {
        let Some(slot) = self.items.get_mut(i) else { return false };
        if name.is_empty() {
            return false;
        }
        slot.set(name)
    }

    /// The NAND blob: `h1`, version, count, then `len` + name per slot.
    pub fn encode<'a>(&self, buf: &'a mut [u8]) -> Option<&'a [u8]> {
        let need = 3 + self.items.iter().map(|s| 1 + s.len as usize).sum::<usize>();
        if buf.len() < need {
            return None;
        }
        buf[0] = BLOB_HEAD[0];
        buf[1] = BLOB_HEAD[1];
        buf[2] = BLOB_VERSION;
        let mut at = 3;
        for slot in &self.items {
            buf[at] = slot.len;
            buf[at + 1..at + 1 + slot.len as usize].copy_from_slice(&slot.buf[..slot.len as usize]);
            at += 1 + slot.len as usize;
        }
        Some(&buf[..at])
    }

    /// Anything that is not this version's blob leaves the defaults in place: a bad blob reads as empty.
    pub fn decode(&mut self, data: &[u8]) -> bool {
        if data.len() < 3 || data[..2] != BLOB_HEAD || data[2] != BLOB_VERSION {
            return false;
        }
        let mut at = 3;
        let mut parsed = Slots { items: self.items };
        for slot in parsed.items.iter_mut().take(SLOTS) {
            let Some(&len) = data.get(at) else { return false };
            let len = len as usize;
            if len == 0 || len > NAME_MAX {
                return false;
            }
            let Some(name) = data.get(at + 1..at + 1 + len) else { return false };
            if name.is_empty() {
                return false;
            }
            slot.set(name);
            at += 1 + len;
        }
        *self = parsed;
        true
    }
}

/// `h1` + kind + payload: the 1–128 byte messages the app and the phone exchange.
const KIND_BEGIN: u8 = b'L'; // phone -> watch: count follows
const KIND_SLOT: u8 = b'S'; // phone -> watch: index + name
const KIND_END: u8 = b'E'; // phone -> watch: count, the list is complete
const KIND_ACK: u8 = b'A'; // phone -> watch: index + status (0 ran, else failed)
const KIND_ASK: u8 = b'R'; // watch -> phone: send me the list
const KIND_RUN: u8 = b'N'; // watch -> phone: run slot i

/// A message from the phone. Anything that is not `h1…` is ignored by the caller.
#[derive(Debug, PartialEq)]
pub enum Incoming<'a> {
    /// `h1L` + count: a list is starting.
    Begin(u8),
    /// `h1S` + index + name: one row of the list.
    Slot { index: u8, name: &'a [u8] },
    /// `h1E` + count: the list is complete.
    End(u8),
    /// `h1A` + index + status: the phone ran that row, or failed to.
    Ack { index: u8, ok: bool },
}

/// Decodes one message. `None` for anything the watch does not use (another app's traffic, a truncated frame).
pub fn parse(msg: &[u8]) -> Option<Incoming<'_>> {
    match msg {
        [b'h', b'1', KIND_BEGIN, count] => Some(Incoming::Begin(*count)),
        [b'h', b'1', KIND_SLOT, index, name @ ..] if !name.is_empty() => {
            Some(Incoming::Slot { index: *index, name })
        }
        [b'h', b'1', KIND_END, count] => Some(Incoming::End(*count)),
        [b'h', b'1', KIND_ACK, index, status] => Some(Incoming::Ack { index: *index, ok: *status == 0 }),
        _ => None,
    }
}

/// The message the watch sends when it still needs the list.
pub fn ask(buf: &mut [u8]) -> usize {
    message(buf, KIND_ASK, &[])
}

/// Run slot `i`: `h1N` + index.
pub fn run(buf: &mut [u8], slot: usize) -> usize {
    message(buf, KIND_RUN, &[slot as u8])
}

fn message(buf: &mut [u8], kind: u8, payload: &[u8]) -> usize {
    let len = 3 + payload.len();
    if buf.len() < len {
        return 0;
    }
    buf[..2].copy_from_slice(b"h1");
    buf[2] = kind;
    buf[3..len].copy_from_slice(payload);
    len
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blob(slots: &Slots) -> ([u8; 128], usize) {
        let mut buf = [0u8; 128];
        let n = slots.encode(&mut buf).unwrap_or(&[]).len();
        (buf, n)
    }

    #[test]
    fn defaults_are_named() {
        let slots = Slots::default();
        assert_eq!(slots.get(0), "Shortcut 1");
        assert_eq!(slots.get(SLOTS - 1), "Shortcut 6");
        assert_eq!(slots.get(SLOTS), "");
    }

    /// The wire the phone speaks (`companion/Sources/Wire.swift`) must agree with this byte for byte, so a tap is
    /// not lost to a one-byte disagreement between the two languages.
    #[test]
    fn wire_messages_match_the_phone() {
        let mut buf = [0u8; 8];
        let n = ask(&mut buf);
        assert_eq!(&buf[..n], b"h1R");
        let n = run(&mut buf, 3);
        assert_eq!(&buf[..n], b"h1N\x03");
        assert_eq!(run(&mut [0u8; 3], 3), 0);
        assert_eq!(ask(&mut [0u8; 2]), 0);
    }

    #[test]
    fn blob_round_trip() {
        let mut slots = Slots::default();
        assert!(slots.set(2, b"Garage"));
        assert!(slots.set(5, b"Lumi\xc3\xa8re"));
        let (buf, n) = blob(&slots);
        let mut read = Slots::default();
        assert!(read.decode(&buf[..n]));
        assert_eq!(read.get(0), "Shortcut 1");
        assert_eq!(read.get(2), "Garage");
        assert_eq!(read.get(5), "Lumière");
    }

    #[test]
    fn bad_blobs_keep_the_defaults() {
        let mut slots = Slots::default();
        for bad in [&b""[..], b"h9\x01", b"h1\x02\x05Garage", b"h1\x01\xffgarage"] {
            assert!(!slots.decode(bad));
            assert_eq!(slots.get(0), "Shortcut 1");
        }
    }

    #[test]
    fn names_cut_on_a_char_boundary() {
        let mut slots = Slots::default();
        let long = "é".repeat(20); // 40 bytes
        assert!(slots.set(0, long.as_bytes()));
        assert_eq!(slots.get(0).len(), 22);
        assert_eq!(slots.get(0).chars().count(), 11);
        assert!(!slots.set(0, b""));
        assert!(!slots.set(SLOTS, b"x"));
    }

    /// Every message the phone sends, decoded the way the app does it.
    #[test]
    fn incoming_messages_are_decoded() {
        assert_eq!(parse(b"h1L\x06"), Some(Incoming::Begin(6)));
        assert_eq!(parse(b"h1S\x02Garage"), Some(Incoming::Slot { index: 2, name: b"Garage" }));
        assert_eq!(parse(b"h1E\x06"), Some(Incoming::End(6)));
        assert_eq!(parse(b"h1A\x02\x00"), Some(Incoming::Ack { index: 2, ok: true }));
        assert_eq!(parse(b"h1A\x02\x01"), Some(Incoming::Ack { index: 2, ok: false }));
    }

    /// Another app's traffic and a half-arrived message must change nothing, not write an empty name.
    #[test]
    fn foreign_and_truncated_messages_are_ignored() {
        for msg in [
            &b""[..],
            b"h9R",
            b"h1Z\x00",
            b"h1S\x00",          // a slot with no name
            b"h1S",              // cut before the index
            b"h1A\x02",          // cut before the status
            b"h1L",              // cut before the count
            b"xyz",
        ] {
            assert_eq!(parse(msg), None, "{msg:?}");
        }
    }

    /// A slot name from the phone goes through `set`, so a 7th row cannot overwrite the 6th or panic.
    #[test]
    fn a_slot_past_the_end_is_refused() {
        let mut slots = Slots::default();
        let Some(Incoming::Slot { index, name }) = parse(b"h1S\x09Seventh") else {
            panic!("not a slot");
        };
        assert!(!slots.set(index as usize, name));
        assert_eq!(slots.get(5), "Shortcut 6");
        assert!(!slots.get(0).contains("Seventh"));
    }

    /// The phone re-sends the whole list on every connect (and the watch asks again when it resumes). A list that
    /// did not change must not count as a change: every `true` here ends in a NAND write.
    #[test]
    fn an_unchanged_name_is_not_a_change() {
        let mut slots = Slots::default();
        assert!(slots.set(0, b"Garage"));
        assert!(!slots.set(0, b"Garage"), "same name, same row");
        assert!(slots.set(0, b"Salon"), "a different name is a change");
        assert!(!slots.set(0, b"Salon"));
        // The clipping is part of the identity: re-sending a 40-byte name must not rewrite what is already stored.
        let long = "é".repeat(20);
        assert!(slots.set(1, long.as_bytes()));
        assert!(!slots.set(1, long.as_bytes()));
    }
}
