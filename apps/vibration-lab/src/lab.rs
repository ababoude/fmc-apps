pub const FREQUENCIES: [u16; 8] = [31, 62, 125, 250, 500, 1000, 4000, 16000];
pub const STOCK_FREQUENCY: u16 = 31;
const GAP_MS: u16 = 80;
const CONTINUOUS_MS: u16 = 1000;

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Pattern {
    Continuous,
    Tick,
    DoubleTick,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Field {
    Strength,
    Frequency,
    Pattern,
    Pulse,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Step {
    pub duty_permille: u16,
    pub freq_hz: u16,
    pub ms: u16,
}

#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Settings {
    pub duty_permille: u16,
    pub freq_hz: u16,
    pub pattern: Pattern,
    pub pulse_ms: u16,
}

impl Default for Settings {
    fn default() -> Self {
        Settings { duty_permille: 200, freq_hz: STOCK_FREQUENCY, pattern: Pattern::Tick, pulse_ms: 20 }
    }
}

fn stepped(value: u16, clicks: i16, step: i32, min: i32, max: i32) -> u16 {
    (value as i32 + clicks as i32 * step).clamp(min, max) as u16
}

impl Settings {
    pub fn adjust(&mut self, field: Field, clicks: i16) {
        match field {
            Field::Strength => self.duty_permille = stepped(self.duty_permille, clicks, 50, 50, 1000),
            Field::Pulse => self.pulse_ms = stepped(self.pulse_ms, clicks, 5, 5, 100),
            Field::Frequency => {
                let at = FREQUENCIES.iter().position(|&f| f >= self.freq_hz).unwrap_or(0);
                let to = (at as i32 + clicks as i32).clamp(0, FREQUENCIES.len() as i32 - 1);
                self.freq_hz = FREQUENCIES[to as usize];
            }
            Field::Pattern => {
                const ALL: [Pattern; 3] = [Pattern::Continuous, Pattern::Tick, Pattern::DoubleTick];
                let at = ALL.iter().position(|&p| p == self.pattern).unwrap_or(0) as i32;
                self.pattern = ALL[(at + clicks as i32).rem_euclid(3) as usize];
            }
        }
    }

    pub fn steps(&self) -> ([Step; 3], usize) {
        let on = |ms| Step { duty_permille: self.duty_permille, freq_hz: self.freq_hz, ms };
        let off = Step { duty_permille: 0, freq_hz: self.freq_hz, ms: GAP_MS };
        match self.pattern {
            Pattern::Continuous => ([on(CONTINUOUS_MS), off, off], 1),
            Pattern::Tick => ([on(self.pulse_ms), off, off], 1),
            Pattern::DoubleTick => ([on(self.pulse_ms), off, on(self.pulse_ms)], 3),
        }
    }
}

pub struct Player {
    steps: [Step; 3],
    len: usize,
    at: usize,
    freq_hz: u16,
    active: bool,
}

impl Player {
    pub fn start(settings: &Settings) -> Self {
        let (steps, len) = settings.steps();
        Player { steps, len, at: 0, freq_hz: settings.freq_hz, active: true }
    }

    pub fn next(&mut self) -> Option<Step> {
        if !self.active {
            return None;
        }
        if self.at < self.len {
            self.at += 1;
            return Some(self.steps[self.at - 1]);
        }
        self.pause();
        Some(Step { duty_permille: 0, freq_hz: self.freq_hz, ms: 0 })
    }

    pub fn pause(&mut self) -> Step {
        self.active = false;
        Step { duty_permille: 0, freq_hz: self.freq_hz, ms: 0 }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strength_clamps() {
        let mut s = Settings::default();
        s.adjust(Field::Strength, 1000);
        assert_eq!(s.duty_permille, 1000);
        s.adjust(Field::Strength, -1000);
        assert_eq!(s.duty_permille, 50);
    }

    #[test]
    fn pulse_clamps() {
        let mut s = Settings::default();
        s.adjust(Field::Pulse, -100);
        assert_eq!(s.pulse_ms, 5);
        s.adjust(Field::Pulse, 100);
        assert_eq!(s.pulse_ms, 100);
    }

    #[test]
    fn frequency_steps_through_list() {
        let mut s = Settings::default();
        assert_eq!(s.freq_hz, 31);
        s.adjust(Field::Frequency, 1);
        assert_eq!(s.freq_hz, 62);
        s.adjust(Field::Frequency, 100);
        assert_eq!(s.freq_hz, 16000);
        s.adjust(Field::Frequency, -100);
        assert_eq!(s.freq_hz, 31);
    }

    #[test]
    fn double_tick_steps() {
        let s = Settings { duty_permille: 300, freq_hz: 200, pattern: Pattern::DoubleTick, pulse_ms: 15 };
        let (steps, n) = s.steps();
        assert_eq!(&steps[..n], &[Step { duty_permille: 300, freq_hz: 200, ms: 15 },
                                  Step { duty_permille: 0, freq_hz: 200, ms: 80 },
                                  Step { duty_permille: 300, freq_hz: 200, ms: 15 }]);
    }

    #[test]
    fn no_step_exceeds_limits() {
        for pattern in [Pattern::Continuous, Pattern::Tick, Pattern::DoubleTick] {
            let mut s = Settings { pattern, ..Settings::default() };
            s.adjust(Field::Strength, i16::MAX);
            s.adjust(Field::Pulse, i16::MAX);
            let (steps, n) = s.steps();
            assert!(steps[..n].iter().all(|st| st.duty_permille <= 1000 && st.ms <= 2000));
        }
    }

    #[test]
    fn pattern_cycles() {
        let mut s = Settings { pattern: Pattern::DoubleTick, ..Settings::default() };
        s.adjust(Field::Pattern, 1);
        assert_eq!(s.pattern, Pattern::Continuous);
        s.adjust(Field::Pattern, -1);
        assert_eq!(s.pattern, Pattern::DoubleTick);
    }

    #[test]
    fn pause_stops_playback() {
        let s = Settings { duty_permille: 300, freq_hz: 200, pattern: Pattern::DoubleTick, pulse_ms: 15 };
        let mut p = Player::start(&s);
        assert!(p.next().is_some());
        assert_eq!(p.pause().duty_permille, 0);
        assert_eq!(p.next(), None);
    }

    #[test]
    fn player_ends_with_motor_off() {
        let s = Settings { pattern: Pattern::Tick, ..Settings::default() };
        let mut p = Player::start(&s);
        assert_eq!(p.next().unwrap().duty_permille, 200);
        assert_eq!(p.next(), Some(Step { duty_permille: 0, freq_hz: 31, ms: 0 }));
        assert_eq!(p.next(), None);
    }
}
