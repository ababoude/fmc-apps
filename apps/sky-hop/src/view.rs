// Drawing, through cmf-wp2-ui's Surface: the watch draws with `&Api`, the tests with `Fb`. One buffer and no
// double buffering, so each frame repaints only what moved and never paints a pixel twice in different colours
// where it can help it (section 2 of the app guide).

use crate::game::{C, GATE_W, Game, Gate, HOP_X, R, SIZE, State};
use cmf_wp2_ui::Rgb;
use cmf_wp2_ui::Surface;
use cmf_wp2_ui::draw::{Band, Paint, radial_n, rrect};
use cmf_wp2_ui::text::{big, big_width, centre, int};

pub const BLACK: Rgb = Rgb(0, 0, 0);
pub const GATE_FILL: Rgb = Rgb(6, 46, 54);
pub const GATE_EDGE: Rgb = Rgb(34, 211, 238);
pub const BODY: Rgb = Rgb(255, 150, 40);
pub const BODY_HIT: Rgb = Rgb(240, 70, 60);
pub const BEAK: Rgb = Rgb(255, 215, 80);
pub const PANEL: Rgb = Rgb(22, 22, 30);
const WHITE: u16 = 0xFFFF;
const GREY: u16 = 0x8C71;

/// Side bars and the caps at the gap.
const BAR: i32 = 4;
const CAP: i32 = 6;
/// The score: font scale 4 (32 px tall), centred on top.
pub const SCORE_Y: i32 = 40;
const SCORE_SCALE: i32 = 4;
const SCORE_H: i32 = 8 * SCORE_SCALE;

/// What was on screen after the last frame.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Seen {
    xs: [i32; crate::game::GATES],
    y: i32,
    score: u32,
    state: State,
}

pub fn seen(g: &Game) -> Seen {
    Seen { xs: g.gates.map(|gt| gt.x), y: g.hop_y(), score: g.score, state: g.state }
}

/// The rects of a gate at `x`, none overlapping: (x, y, w, h, colour).
fn gate_rects(gt: &Gate, x: i32) -> [(i32, i32, i32, i32, Rgb); 8] {
    let (top, bottom) = (gt.top - CAP, gt.bottom + CAP);
    let low = SIZE - bottom;
    [
        (x, 0, BAR, top, GATE_EDGE),
        (x + BAR, 0, GATE_W - 2 * BAR, top, GATE_FILL),
        (x + GATE_W - BAR, 0, BAR, top, GATE_EDGE),
        (x, top, GATE_W, CAP, GATE_EDGE),
        (x, gt.bottom, GATE_W, CAP, GATE_EDGE),
        (x, bottom, BAR, low, GATE_EDGE),
        (x + BAR, bottom, GATE_W - 2 * BAR, low, GATE_FILL),
        (x + GATE_W - BAR, bottom, BAR, low, GATE_EDGE),
    ]
}

/// What lies under the critter and the score: a gate or the black sky.
fn under(g: &Game, x: i32, y: i32) -> Rgb {
    for gt in &g.gates {
        for (rx, ry, w, h, c) in gate_rects(gt, gt.x) {
            if x >= rx && x < rx + w && y >= ry && y < ry + h {
                return c;
            }
        }
    }
    BLACK
}

/// The background of a box: black, then the parts of gates in it.
fn background(s: &mut impl Surface, g: &Game, x0: i32, y0: i32, w: i32, h: i32) {
    s.rect(x0, y0, w, h, BLACK.rgb565());
    for gt in &g.gates {
        for (x, y, rw, rh, c) in gate_rects(gt, gt.x) {
            let (ax, ay) = (x.max(x0), y.max(y0));
            let (bx, by) = ((x + rw).min(x0 + w), (y + rh).min(y0 + h));
            s.rect(ax, ay, bx - ax, by - ay, c.rgb565());
        }
    }
}

/// A gate at its new place; with `from`, also erase the strip it left behind on the right.
fn gate(s: &mut impl Surface, gt: &Gate, from: Option<i32>) {
    if gt.x >= SIZE && from.is_none_or(|x| x >= SIZE) {
        return;
    }
    for (x, y, w, h, c) in gate_rects(gt, gt.x) {
        s.rect(x, y, w, h, c.rgb565());
    }
    if let Some(old) = from {
        let x0 = (gt.x + GATE_W).max(old);
        s.rect(x0, 0, old + GATE_W - x0, SIZE, BLACK.rgb565());
    }
}

/// The critter at its height; `from`: its last height, whose box gets the background back in the same pass.
fn critter(s: &mut impl Surface, g: &Game, from: Option<i32>) {
    let y = g.hop_y();
    let (lo, hi) = from.map_or((y, y), |f| (f.min(y), f.max(y)));
    let body = if g.state == State::Over { BODY_HIT } else { BODY };
    let clear = [HOP_X - R - 2, lo - R - 2, HOP_X + R + 7, hi + R + 3];
    radial_n::<1>(s, HOP_X, y, &[Band { r: R, paint: Paint::Solid(body), soft: 1 }], Some(clear), |x, y| under(g, x, y));
    s.rect(HOP_X + R - 2, y - 1, 7, 5, BEAK.rgb565());
    s.rect(HOP_X + 3, y - 8, 6, 6, WHITE);
    let pupil = if g.state == State::Over { (HOP_X + 4, y - 7) } else { (HOP_X + 6, y - 6) };
    s.rect(pupil.0, pupil.1, 3, 3, BLACK.rgb565());
}

fn score(s: &mut impl Surface, g: &Game, clear: bool) {
    let mut buf = [0u8; 11];
    let text = int(g.score as i32, &mut buf);
    if clear {
        background(s, g, C - 80, SCORE_Y, 160, SCORE_H);
    }
    big(s, C - big_width(text, SCORE_SCALE) / 2, SCORE_Y, text, SCORE_SCALE, WHITE);
}

fn best_line(s: &mut impl Surface, y: i32, best: u32) {
    let mut buf = [0u8; 11];
    let mut line = [0u8; 16];
    let n = int(best as i32, &mut buf).as_bytes();
    line[..5].copy_from_slice(b"BEST ");
    line[5..5 + n.len()].copy_from_slice(n);
    centre(s, C, y, core::str::from_utf8(&line[..5 + n.len()]).unwrap_or("?"), GREY);
}

fn ready(s: &mut impl Surface, best: u32) {
    const TITLE: &str = "SKY HOP";
    big(s, C - big_width(TITLE, 4) / 2, 112, TITLE, 4, BODY.rgb565());
    centre(s, C, 316, "TAP TO FLY", WHITE);
    if best > 0 {
        best_line(s, 346, best);
    }
}

fn over(s: &mut impl Surface, g: &Game, best: u32) {
    rrect(s, C - 140, 150, 280, 170, 28, PANEL, BLACK);
    const TITLE: &str = "GAME OVER";
    big(s, C - big_width(TITLE, 3) / 2, 172, TITLE, 3, BODY_HIT.rgb565());
    let mut buf = [0u8; 11];
    let text = int(g.score as i32, &mut buf);
    big(s, C - big_width(text, 6) / 2, 210, text, 6, WHITE);
    best_line(s, 264, best);
    centre(s, C, 290, "TAP TO RETRY", GREY);
}

/// Draws the frame for `g`. `prev`: what is on screen now; `None`, or another state, repaints everything.
pub fn frame(s: &mut impl Surface, g: &Game, best: u32, prev: Option<Seen>) -> Seen {
    let now = seen(g);
    let prev = prev.filter(|p| p.state == g.state);
    match prev {
        None => {
            s.rect(0, 0, SIZE, SIZE, BLACK.rgb565());
            for gt in &g.gates {
                gate(s, gt, None);
            }
            critter(s, g, None);
            match g.state {
                State::Ready => ready(s, best),
                State::Playing => score(s, g, false),
                State::Over => {
                    score(s, g, false);
                    over(s, g, best);
                }
            }
        }
        Some(p) if p == now => {}
        Some(p) => {
            if g.state == State::Playing {
                for (gt, x) in g.gates.iter().zip(p.xs) {
                    gate(s, gt, Some(x));
                }
            }
            critter(s, g, Some(p.y));
            if g.state == State::Playing {
                score(s, g, p.score != g.score);
            }
        }
    }
    now
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::game::{GATES, Step};
    use cmf_wp2_ui::Fb;
    use std::vec;
    use std::vec::Vec;

    fn screen() -> Vec<u16> {
        vec![0u16; (SIZE * SIZE) as usize]
    }

    fn full(g: &Game, best: u32) -> Vec<u16> {
        let mut px = screen();
        frame(&mut Fb::new(&mut px), g, best, None);
        px
    }

    /// Frame by frame, what the watch ends up with must be what a full repaint draws.
    #[test]
    fn partial_frames_match_a_full_repaint() {
        for seed in [1u32, 8, 77] {
            let mut g = Game::new(seed);
            let mut px = screen();
            let mut prev = None;
            let mut checked = 0;
            for tick in 0..900u32 {
                if tick == 5 || (g.state == State::Playing && tick % 13 == 0) {
                    g.flap();
                }
                if g.state == State::Over {
                    break;
                }
                let _: Step = g.step();
                prev = Some(frame(&mut Fb::new(&mut px), &g, 3, prev));
                if tick % 7 == 0 || g.state == State::Over {
                    let want = full(&g, 3);
                    let bad = px.iter().zip(&want).position(|(a, b)| a != b);
                    assert_eq!(bad.map(|i| (i as i32 % SIZE, i as i32 / SIZE)), None, "seed {seed} tick {tick}");
                    checked += 1;
                }
            }
            assert!(checked > 5);
        }
    }

    #[test]
    fn a_still_frame_draws_nothing() {
        let g = Game::new(4);
        let mut px = screen();
        let mut fb = Fb::new(&mut px);
        let p = frame(&mut fb, &g, 0, None);
        let rects = fb.rects;
        frame(&mut fb, &g, 0, Some(p));
        assert_eq!(fb.rects, rects);
    }

    #[test]
    fn critter_is_drawn_where_it_is() {
        let g = Game::new(4);
        let px = full(&g, 0);
        let fb_at = |x: i32, y: i32| px[(y * SIZE + x) as usize];
        assert_eq!(fb_at(HOP_X - 5, g.hop_y() + 5), BODY.rgb565());
        assert_eq!(fb_at(HOP_X - R - 4, g.hop_y()), BLACK.rgb565());
    }

    #[test]
    fn gate_parts_do_not_overlap() {
        let gt = Gate { x: 100, top: 150, bottom: 290, ..Game::new(1).gates[0] };
        let rects = gate_rects(&gt, gt.x);
        for (i, a) in rects.iter().enumerate() {
            for b in &rects[i + 1..] {
                let apart = a.0 + a.2 <= b.0 || b.0 + b.2 <= a.0 || a.1 + a.3 <= b.1 || b.1 + b.3 <= a.1;
                assert!(apart, "{a:?} {b:?}");
            }
        }
        let area: i32 = rects.iter().map(|r| r.2 * r.3).sum();
        assert_eq!(area, GATE_W * (SIZE - (gt.bottom - gt.top)));
        assert_eq!(GATES, 3);
    }
}
