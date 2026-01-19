use std::collections::VecDeque;
use std::env;
use std::fs::OpenOptions;
use std::io::Write;
use std::time::Instant;

use gpui::{
    App, Application, Bounds, Context, ElementId, Entity, Window, WindowBounds, WindowOptions,
    deferred, div, prelude::*, px, rgb, size,
};

#[cfg(feature = "fiber")]
fn format_bytes(bytes: usize) -> String {
    if bytes >= 1_000_000 {
        format!("{:.2} MB", bytes as f64 / 1_000_000.0)
    } else if bytes >= 1_000 {
        format!("{:.1} KB", bytes as f64 / 1_000.0)
    } else {
        format!("{} B", bytes)
    }
}

#[cfg(feature = "fiber")]
fn log_frame(diag: &gpui::FrameDiagnostics) {
    use std::sync::Once;
    static INIT: Once = Once::new();

    INIT.call_once(|| {
        if let Ok(mut f) = OpenOptions::new().create(true).write(true).truncate(true).open("frame_log.csv") {
            let _ = writeln!(f, "frame,paint_fibers,paint_replayed,prepaint_fibers,prepaint_replayed,mutated_segments,total_segments,hitboxes,hitboxes_rebuilt,upload_bytes,quads,mono_sprites,poly_sprites");
        }
    });

    if let Ok(mut f) = OpenOptions::new().append(true).open("frame_log.csv") {
        let _ = writeln!(f, "{},{},{},{},{},{},{},{},{},{},{},{},{}",
            diag.frame_number,
            diag.paint_fibers,
            diag.paint_replayed_subtrees,
            diag.prepaint_fibers,
            diag.prepaint_replayed_subtrees,
            diag.mutated_pool_segments,
            diag.total_pool_segments,
            diag.hitboxes_in_snapshot,
            diag.hitboxes_snapshot_rebuilt,
            diag.estimated_instance_upload_bytes,
            diag.quads,
            diag.monochrome_sprites,
            diag.polychrome_sprites,
        );
    }
}

fn env_bool(name: &str, default: bool) -> bool {
    env::var(name)
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(default)
}

fn env_usize(name: &str, default: usize) -> usize {
    env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

fn env_f32(name: &str, default: f32) -> f32 {
    env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

const DEFAULT_ROWS: usize = 50;
const DEFAULT_CELL_SIZE: f32 = 32.0;
const DEFAULT_WIDTH: f32 = 800.0;
const DEFAULT_HEIGHT: f32 = 600.0;
const CELL_GAP: f32 = 4.0;
const GRID_PADDING: f32 = 16.0;
const FRAME_HISTORY: usize = 60;

struct FpsCounter {
    times: VecDeque<Instant>,
    fps: f64,
}

impl FpsCounter {
    fn new() -> Self {
        Self {
            times: VecDeque::with_capacity(FRAME_HISTORY + 1),
            fps: 0.0,
        }
    }

    fn record(&mut self) {
        let now = Instant::now();
        self.times.push_back(now);

        if self.times.len() > FRAME_HISTORY {
            self.times.pop_front();
        }

        if self.times.len() >= 2 {
            if let Some(oldest) = self.times.front() {
                let elapsed = now.duration_since(*oldest).as_secs_f64();
                self.fps = (self.times.len() - 1) as f64 / elapsed;
            }
        }
    }
}

struct FpsView {
    render_fps: FpsCounter,
    frame_fps: FpsCounter,
}

impl FpsView {
    fn new() -> Self {
        Self {
            render_fps: FpsCounter::new(),
            frame_fps: FpsCounter::new(),
        }
    }

    fn schedule_frame_callback(this: Entity<Self>, window: &mut Window) {
        let this_weak = this.downgrade();
        window.on_next_frame(move |window, cx| {
            if let Some(this) = this_weak.upgrade() {
                this.update(cx, |fps_view, cx| {
                    fps_view.frame_fps.record();
                    cx.notify();
                });
                Self::schedule_frame_callback(this, window);
            }
        });
    }
}

impl Render for FpsView {
    fn render(&mut self, window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        window.request_animation_frame();
        self.render_fps.record();

        #[cfg(feature = "fiber")]
        {
            let diag = window.frame_diagnostics();
            log_frame(&diag);

            let section = |title: &str| {
                div()
                    .text_color(rgb(0xffff00))
                    .pt_2()
                    .child(title.to_string())
            };

            let line = |label: &str, value: String| {
                div()
                    .flex()
                    .flex_row()
                    .justify_between()
                    .gap_4()
                    .child(div().text_color(rgb(0x888888)).child(label.to_string()))
                    .child(div().text_color(rgb(0xffffff)).child(value))
            };

            div()
                .flex()
                .flex_col()
                .text_xs()
                .child(
                    div()
                        .text_color(rgb(0x00ff00))
                        .font_weight(gpui::FontWeight::BOLD)
                        .child(format!("Frame #{} @ {:.0} FPS", diag.frame_number, self.render_fps.fps)),
                )
                .child(section("CPU Paint"))
                .child(line("paint", format!("{} / {} repl", diag.paint_fibers, diag.paint_replayed_subtrees)))
                .child(line("prepaint", format!("{} / {} repl", diag.prepaint_fibers, diag.prepaint_replayed_subtrees)))
                .child(section("Scene"))
                .child(line("segments", format!("{} / {}", diag.mutated_pool_segments, diag.total_pool_segments)))
                .child(line("hitboxes", format!("{} (rebuilt: {})", diag.hitboxes_in_snapshot, diag.hitboxes_snapshot_rebuilt)))
                .child(section("GPU"))
                .child(line("upload", format_bytes(diag.estimated_instance_upload_bytes)))
                .child(line("quads", diag.quads.to_string()))
                .child(line("sprites", format!("{} / {}", diag.monochrome_sprites, diag.polychrome_sprites)))
        }

        #[cfg(not(feature = "fiber"))]
        {
            div()
                .flex()
                .flex_col()
                .text_xs()
                .child(
                    div()
                        .text_color(rgb(0x00ff00))
                        .font_weight(gpui::FontWeight::BOLD)
                        .child(format!("{:.0} FPS", self.render_fps.fps)),
                )
        }
    }
}

struct GridBench {
    fps_view: Entity<FpsView>,
    row_count: usize,
    cell_size: f32,
    enable_hover: bool,
    enable_click: bool,
    step_size: usize,
}

impl GridBench {
    fn new(fps_view: Entity<FpsView>) -> Self {
        Self {
            fps_view,
            row_count: env_usize("GRID_BENCH_ROWS", DEFAULT_ROWS),
            cell_size: env_f32("GRID_BENCH_CELL_SIZE", DEFAULT_CELL_SIZE),
            enable_hover: env_bool("GRID_BENCH_HOVER", true),
            enable_click: env_bool("GRID_BENCH_CLICK", true),
            step_size: env_usize("GRID_BENCH_STEP", 1),
        }
    }

    fn add_row(&mut self) {
        self.row_count += self.step_size;
    }

    fn remove_row(&mut self) {
        self.row_count = self.row_count.saturating_sub(self.step_size).max(1);
    }

    fn increase_cell_size(&mut self) {
        self.cell_size = (self.cell_size + 4.0).min(128.0);
    }

    fn decrease_cell_size(&mut self) {
        self.cell_size = (self.cell_size - 4.0).max(8.0);
    }

    fn calculate_col_count(&self, window_width: f32) -> usize {
        let available_width = window_width - (GRID_PADDING * 2.0);
        let cell_with_gap = self.cell_size + CELL_GAP;
        ((available_width + CELL_GAP) / cell_with_gap).floor().max(1.0) as usize
    }
}

impl Render for GridBench {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let window_width: f32 = window.viewport_size().width.into();
        let col_count = self.calculate_col_count(window_width);
        let row_count = self.row_count;
        let total_cells = row_count * col_count;
        let cell_size = self.cell_size;
        let enable_hover = self.enable_hover;
        let enable_click = self.enable_click;

        div()
            .size_full()
            .bg(rgb(0x1e1e1e))
            .child(deferred(
                div()
                    .absolute()
                    .top_2()
                    .left_2()
                    .px_3()
                    .py_2()
                    .bg(gpui::black().opacity(0.7))
                    .block_mouse_except_scroll()
                    .rounded_md()
                    .text_sm()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .gap_1()
                            .child(self.fps_view.clone())
                            .child(
                                div()
                                    .text_color(rgb(0xaaaaaa))
                                    .child(format!(
                                        "Grid: {}x{} ({} cells) @ {}px",
                                        row_count, col_count, total_cells, cell_size as u32
                                    )),
                            )
                            .child(
                                div()
                                    .text_color(if cfg!(debug_assertions) {
                                        rgb(0xff8800)
                                    } else {
                                        rgb(0x00ff88)
                                    })
                                    .child(if cfg!(debug_assertions) {
                                        "Build: DEBUG"
                                    } else {
                                        "Build: RELEASE"
                                    }),
                            )
                            .child(
                                div()
                                    .text_color(if cfg!(feature = "fiber") {
                                        rgb(0xff00ff)
                                    } else {
                                        rgb(0x00aaff)
                                    })
                                    .child(if cfg!(feature = "fiber") {
                                        "GPUI: Fiber"
                                    } else {
                                        "GPUI: Upstream"
                                    }),
                            ),
                    )
                    .child(
                        div()
                            .flex()
                            .gap_2()
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(div().text_color(rgb(0x888888)).child("Rows"))
                                    .child(
                                        div()
                                            .flex()
                                            .gap_1()
                                            .child(
                                                self.control_button(
                                                    "row-",
                                                    "-",
                                                    cx.listener(|this, _, _, cx| {
                                                        this.remove_row();
                                                        cx.notify();
                                                    }),
                                                ),
                                            )
                                            .child(
                                                self.control_button(
                                                    "row+",
                                                    "+",
                                                    cx.listener(|this, _, _, cx| {
                                                        this.add_row();
                                                        cx.notify();
                                                    }),
                                                ),
                                            ),
                                    ),
                            )
                            .child(
                                div()
                                    .flex()
                                    .flex_col()
                                    .gap_1()
                                    .child(div().text_color(rgb(0x888888)).child("Cell Size"))
                                    .child(
                                        div()
                                            .flex()
                                            .gap_1()
                                            .child(
                                                self.control_button(
                                                    "size-",
                                                    "-",
                                                    cx.listener(|this, _, _, cx| {
                                                        this.decrease_cell_size();
                                                        cx.notify();
                                                    }),
                                                ),
                                            )
                                            .child(
                                                self.control_button(
                                                    "size+",
                                                    "+",
                                                    cx.listener(|this, _, _, cx| {
                                                        this.increase_cell_size();
                                                        cx.notify();
                                                    }),
                                                ),
                                            ),
                                    ),
                            ),
                    ),
            ))
            .child(
                div()
                    .size_full()
                    .id("scroll")
                    .overflow_scroll()
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .p(px(GRID_PADDING))
                            .gap(px(CELL_GAP))
                            .children((0..row_count).map(move |row| {
                                div()
                                    .flex()
                                    .gap(px(CELL_GAP))
                                    .children((0..col_count).map(move |col| {
                                        let cell_num = row * col_count + col;
                                        let hue =
                                            (cell_num as f32 / total_cells.max(1) as f32 * 360.0) as u32;
                                        let color = hsv_to_rgb(hue, 70, 60);
                                        let hover_color = hsv_to_rgb(hue, 80, 80);
                                        div()
                                            .id(ElementId::NamedInteger("cell".into(), cell_num as u64))
                                            .size(px(cell_size))
                                            .rounded_sm()
                                            .bg(color)
                                            .when(enable_hover, |this| {
                                                this.hover(|style| {
                                                    style.bg(hover_color).border_1().border_color(gpui::white())
                                                })
                                            })
                                            .flex()
                                            .items_center()
                                            .justify_center()
                                            .text_xs()
                                            .text_color(gpui::white())
                                            .child(format!("{}", cell_num))
                                            .when(enable_click, |this| {
                                                this.on_click(move |_event, _window, _cx| {
                                                    log::info!("Clicked cell {}", cell_num);
                                                })
                                            })
                                    }))
                            })),
                    ),
            )
    }
}

impl GridBench {
    fn control_button(
        &self,
        id: &'static str,
        label: &'static str,
        on_click: impl Fn(&gpui::ClickEvent, &mut Window, &mut App) + 'static,
    ) -> impl IntoElement {
        div()
            .id(id)
            .px_2()
            .py_1()
            .bg(rgb(0x444444))
            .hover(|style| style.bg(rgb(0x555555)))
            .active(|style| style.bg(rgb(0x333333)))
            .rounded_sm()
            .cursor_pointer()
            .text_color(gpui::white())
            .child(label)
            .on_click(on_click)
    }

}

fn hsv_to_rgb(h: u32, s: u32, v: u32) -> gpui::Hsla {
    gpui::hsla(h as f32 / 360.0, s as f32 / 100.0, v as f32 / 100.0, 1.0)
}

fn main() {
    env_logger::Builder::from_default_env()
        .filter_level(log::LevelFilter::Info)
        .init();

    let window_width = env_f32("GRID_BENCH_WIDTH", DEFAULT_WIDTH);
    let window_height = env_f32("GRID_BENCH_HEIGHT", DEFAULT_HEIGHT);

    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(window_width), px(window_height)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            |window, cx| {
                let fps_view = cx.new(|_| FpsView::new());
                FpsView::schedule_frame_callback(fps_view.clone(), window);
                cx.new(|_| GridBench::new(fps_view))
            },
        )
        .unwrap();
        cx.activate(true);
    });
}
