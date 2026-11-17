#![cfg_attr(any(target_os = "none", wp2_sim), no_main, cfg_attr(target_os = "none", no_std))]

//! Send a Shortcut to the phone. The watch has no network: a tap only tells the iPhone companion (`companion/`)
//! which row it was, and the companion runs the Shortcut or POSTs the webhook. Protocol: `src/model.rs`.

mod model;

#[cfg(not(any(target_os = "none", wp2_sim)))]
fn main() {}

#[cfg(any(target_os = "none", wp2_sim))]
mod device {
    use crate::model::{self, Slots, SLOTS};
    use cmf_wp2_app::{Api, BUTTON, CROWN, MESSAGE, MSG_MAX, PAUSE, RESUME, TOUCH_DOWN};
    use core::fmt::Write;

    cmf_wp2_app::entry!(main);
    cmf_wp2_app::app_icon!();

    const ROW_TOP: i16 = 108;
    const ROW_HEIGHT: i16 = 50;
    const ROW_WIDTH: u16 = 320;
    const BLACK: u16 = 0x0000;
    const WHITE: u16 = 0xFFFF;
    const GREY: u16 = 0x39E7;
    const ACCENT: u16 = 0x35BE;
    const DIM: u16 = 0x7BEF;
    /// Under the sixth row, high enough that the round panel does not cut a 19-character line.
    const STATUS_Y: i16 = 396;
    const ASK_MS: u32 = 4000;
    const TOAST_MS: u32 = 1500;

    /// A short line: 23 bytes, the budget a slot name has.
    struct Line {
        buf: [u8; 23],
        len: usize,
    }

    impl Line {
        fn new() -> Self {
            Line { buf: [0; 23], len: 0 }
        }

        fn as_str(&self) -> &str {
            core::str::from_utf8(&self.buf[..self.len]).unwrap_or("")
        }
    }

    impl Write for Line {
        fn write_str(&mut self, s: &str) -> core::fmt::Result {
            let mut n = s.len().min(self.buf.len() - self.len);
            while n > 0 && !s.is_char_boundary(n) {
                n -= 1;
            }
            self.buf[self.len..self.len + n].copy_from_slice(&s.as_bytes()[..n]);
            self.len += n;
            Ok(())
        }
    }

    /// `text` clipped to `max` bytes on a char boundary, drawn centred at `y`.
    fn centred(api: &Api, y: i16, text: &str, max: usize, rgb: u16) {
        let mut line = Line::new();
        let mut n = text.len().min(max);
        while n > 0 && !text.is_char_boundary(n) {
            n -= 1;
        }
        let _ = line.write_str(&text[..n]);
        let width = 16 * line.as_str().chars().count() as i16;
        api.text(api.width as i16 / 2 - width / 2, y, line.as_str(), rgb);
    }

    struct View {
        slots: Slots,
        selected: usize,
        /// The last thing the phone said, drawn under the list until `toast_until`.
        toast: Line,
        toast_until: u32,
        linked: bool,
        waiting: bool,
        /// A slot changed since the last NAND write, and a snapshot is still arriving.
        dirty: bool,
        batch: bool,
    }

    impl View {
        fn new() -> Self {
            View {
                slots: Slots::default(),
                selected: 0,
                toast: Line::new(),
                toast_until: 0,
                linked: false,
                waiting: false,
                dirty: false,
                batch: false,
            }
        }

        fn say(&mut self, api: &Api, text: &str) {
            self.toast = Line::new();
            let _ = self.toast.write_str(text);
            self.toast_until = api.now().wrapping_add(TOAST_MS);
        }

        fn status(&self, api: &Api) -> &str {
            if (self.toast_until.wrapping_sub(api.now()) as i32) > 0 {
                self.toast.as_str()
            } else if self.waiting {
                "Sending..."
            } else if self.linked {
                "Phone ready"
            } else {
                "Open iPhone app"
            }
        }
    }

    fn draw(api: &Api, view: &View) {
        api.rect(0, 0, api.width, api.height, BLACK);
        centred(api, 62, "Shortcuts", 9, WHITE);
        for row in 0..SLOTS {
            let y = ROW_TOP + row as i16 * ROW_HEIGHT;
            let selected = row == view.selected;
            if selected {
                api.rect(
                    api.width as i16 / 2 - ROW_WIDTH as i16 / 2,
                    y - 10,
                    ROW_WIDTH,
                    (ROW_HEIGHT - 6) as u16,
                    GREY,
                );
            }
            centred(api, y, view.slots.get(row), 18, if selected { ACCENT } else { WHITE });
        }
        centred(api, STATUS_Y, view.status(api), 19, DIM);
        api.show();
    }

    fn row_at(y: i16) -> Option<usize> {
        let row = (y - ROW_TOP + 10) / ROW_HEIGHT;
        (0..SLOTS as i16).contains(&row).then_some(row as usize)
    }

    fn send(api: &Api, view: &mut View, msg: &[u8]) {
        match api.send(msg) {
            0 => view.waiting = true,
            _ => {
                view.linked = false;
                view.say(api, "No phone: open the app");
            }
        }
    }

    /// Returns true when the blob should be written: once per `L…E` batch, not once per slot.
    fn drain(api: &Api, view: &mut View, buf: &mut [u8; MSG_MAX]) -> bool {
        while let Some(m) = api.recv(buf) {
            match model::parse(m) {
                Some(model::Incoming::Begin(_)) => {
                    view.batch = true;
                    view.linked = true;
                }
                Some(model::Incoming::Slot { index, name }) => {
                    // A slot past the panel's six is refused by `set`, not wrapped onto another row.
                    if view.slots.set(index as usize, name) {
                        view.dirty = true;
                    }
                    view.linked = true;
                }
                Some(model::Incoming::End(_)) => {
                    view.batch = false;
                    view.linked = true;
                    view.say(api, "List updated");
                }
                Some(model::Incoming::Ack { ok, .. }) => {
                    view.waiting = false;
                    view.linked = true;
                    view.say(api, if ok { "Sent to iPhone" } else { "Shortcut failed" });
                }
                None => {}
            }
        }
        // A phone that never sends `L`/`E` still gets its slots saved, one write per message.
        let save = view.dirty && !view.batch;
        view.dirty &= view.batch;
        save
    }

    fn main(api: &'static Api) -> i32 {
        let mut view = View::new();
        let mut stored = [0u8; 256];
        let n = api.load(&mut stored);
        if n > 0 {
            view.slots.decode(&stored[..n as usize]);
        }
        let mut asked: Option<u32> = None;
        let mut buf = [0u8; MSG_MAX];
        draw(api, &view);
        loop {
            let now = api.now();
            if !view.linked && asked.is_none_or(|t| now.wrapping_sub(t) >= ASK_MS) {
                let mut msg = [0u8; 8];
                let len = model::ask(&mut msg);
                if api.send(&msg[..len]) == 0 {
                    asked = Some(now);
                }
            }
            let left = (view.toast_until.wrapping_sub(now) as i32).clamp(0, 250) as u32;
            let Some(event) = api.event(left) else {
                if view.toast_until.wrapping_sub(api.now()) as i32 <= 0 && view.toast.len > 0 {
                    view.toast = Line::new();
                    draw(api, &view);
                }
                continue;
            };
            match event.kind {
                BUTTON => return 0,
                PAUSE => {
                    if !paused(api) {
                        return 0;
                    }
                    view.linked = false;
                    view.waiting = false;
                    asked = None;
                    draw(api, &view);
                }
                RESUME => {
                    asked = None;
                    draw(api, &view);
                }
                TOUCH_DOWN => {
                    if let Some(row) = row_at(event.y) {
                        view.selected = row;
                        let mut msg = [0u8; 8];
                        let len = model::run(&mut msg, row);
                        send(api, &mut view, &msg[..len]);
                        draw(api, &view);
                    }
                }
                CROWN if event.delta != 0 => {
                    view.selected =
                        (view.selected as i16 + event.delta.signum()).clamp(0, SLOTS as i16 - 1) as usize;
                    draw(api, &view);
                }
                MESSAGE => {
                    if drain(api, &mut view, &mut buf) {
                        let mut encoded = [0u8; 256];
                        if let Some(blob) = view.slots.encode(&mut encoded) {
                            api.save(blob); // on a change, not per frame: this writes NAND
                        }
                    }
                    draw(api, &view);
                }
                _ => {}
            }
        }
    }

    /// true on RESUME, false on BUTTON.
    fn paused(api: &Api) -> bool {
        loop {
            match api.event(u32::MAX).map(|e| e.kind) {
                Some(RESUME) => return true,
                Some(BUTTON) => return false,
                _ => {}
            }
        }
    }
}
