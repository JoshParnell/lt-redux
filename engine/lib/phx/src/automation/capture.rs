use std::io::Cursor;

use image::imageops::{self, FilterType};
use image::{ImageFormat, RgbImage};
use serde_json::Value;

pub(super) struct CaptureOptions {
    /// Fraction of the window size, in (0, 1].
    pub scale: f64,
    /// `[x, y, width, height]` in window pixels, origin at the top left.
    pub region: Option<[u32; 4]>,
    /// Write the PNG to this path instead of returning it.
    pub save: Option<String>,
}

impl CaptureOptions {
    pub fn parse(args: &Value) -> Result<Self, String> {
        let scale = args.get("scale").and_then(Value::as_f64).unwrap_or(1.0);
        if scale <= 0.0 || scale > 1.0 {
            return Err("scale must be in (0, 1]".into());
        }

        let region = match args.get("region") {
            None | Some(Value::Null) => None,
            Some(region) => {
                let values: Vec<u32> = region
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_u64)
                    .map(|value| value as u32)
                    .collect();
                Some(
                    values
                        .try_into()
                        .map_err(|_| "region must be [x, y, width, height]")?,
                )
            }
        };

        let save = args.get("save").and_then(Value::as_str).map(str::to_string);

        Ok(Self {
            scale,
            region,
            save,
        })
    }
}

pub(super) struct Png {
    pub data: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Turn a bottom-up RGBA back buffer readback into a PNG.
pub(super) fn encode(
    pixels: &[u8],
    width: u32,
    height: u32,
    options: &CaptureOptions,
) -> Result<Png, String> {
    let stride = width as usize * 4;
    if stride == 0 || pixels.len() != stride * height as usize {
        return Err("The back buffer readback came back empty".into());
    }

    // Alpha is dropped: the window is opaque whatever the shaders wrote there.
    let mut rgb = Vec::with_capacity(width as usize * height as usize * 3);
    for row in pixels.chunks_exact(stride).rev() {
        for pixel in row.chunks_exact(4) {
            rgb.extend_from_slice(&pixel[..3]);
        }
    }
    let mut image = RgbImage::from_raw(width, height, rgb).ok_or("Bad readback size")?;

    if let Some([x, y, w, h]) = options.region {
        let (x, y) = (x.min(width), y.min(height));
        let (w, h) = (w.min(width - x), h.min(height - y));
        if w == 0 || h == 0 {
            return Err("region is outside the window".into());
        }
        image = imageops::crop_imm(&image, x, y, w, h).to_image();
    }

    if options.scale < 1.0 {
        let w = ((image.width() as f64 * options.scale).round() as u32).max(1);
        let h = ((image.height() as f64 * options.scale).round() as u32).max(1);
        image = imageops::resize(&image, w, h, FilterType::Triangle);
    }

    let mut data = Vec::new();
    image
        .write_to(&mut Cursor::new(&mut data), ImageFormat::Png)
        .map_err(|err| err.to_string())?;

    Ok(Png {
        data,
        width: image.width(),
        height: image.height(),
    })
}
