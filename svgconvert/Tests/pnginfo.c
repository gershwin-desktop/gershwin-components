/*
 * Copyright (c) 2026 Simon Peter
 *
 * SPDX-License-Identifier: BSD-2-Clause OR GPL-3.0-or-later
 */

/* Reads PNGs back for the svgconvert tests with the decoder plutovg already
   bundles, so the tests need neither ImageMagick nor Python.

   svgconvert_pnginfo FILE           prints "W H"
   svgconvert_pnginfo FILE X Y       prints "W H R G B A" of that pixel
   svgconvert_pnginfo -psnr A B      prints the PSNR in dB of B against A over
                                     premultiplied RGBA, 99 for identical
                                     images; exits 2 if the sizes differ */

#include <plutovg.h>

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static plutovg_surface_t *load(const char *path)
{
    plutovg_surface_t *surface = plutovg_surface_load_from_image_file(path);
    if (surface == NULL)
        fprintf(stderr, "pnginfo: cannot read %s\n", path);
    return surface;
}

/* plutovg keeps native-endian premultiplied ARGB words. */
static uint32_t pixelAt(const plutovg_surface_t *surface, int x, int y)
{
    const unsigned char *row = plutovg_surface_get_data(surface)
                             + (size_t)y * (size_t)plutovg_surface_get_stride(surface);
    uint32_t value;
    memcpy(&value, row + (size_t)x * 4, sizeof value);
    return value;
}

static int psnr(const char *pathA, const char *pathB)
{
    plutovg_surface_t *a = load(pathA);
    plutovg_surface_t *b = load(pathB);
    if (a == NULL || b == NULL)
        return 1;
    int w = plutovg_surface_get_width(a);
    int h = plutovg_surface_get_height(a);
    if (w != plutovg_surface_get_width(b) || h != plutovg_surface_get_height(b)) {
        printf("size mismatch %dx%d %dx%d\n", w, h,
               plutovg_surface_get_width(b), plutovg_surface_get_height(b));
        return 2;
    }
    double sum = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            uint32_t pa = pixelAt(a, x, y);
            uint32_t pb = pixelAt(b, x, y);
            for (int shift = 0; shift < 32; shift += 8) {
                double d = (double)((pa >> shift) & 0xff) - (double)((pb >> shift) & 0xff);
                sum += d * d;
            }
        }
    }
    double mse = sum / ((double)w * h * 4);
    printf("%.2f\n", mse == 0 ? 99.0 : 10 * log10(255.0 * 255.0 / mse));
    plutovg_surface_destroy(a);
    plutovg_surface_destroy(b);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 4 && strcmp(argv[1], "-psnr") == 0)
        return psnr(argv[2], argv[3]);
    if (argc != 2 && argc != 4) {
        fprintf(stderr, "usage: pnginfo FILE [X Y] | pnginfo -psnr A B\n");
        return 1;
    }
    plutovg_surface_t *surface = load(argv[1]);
    if (surface == NULL)
        return 1;
    int w = plutovg_surface_get_width(surface);
    int h = plutovg_surface_get_height(surface);
    if (argc == 2) {
        printf("%d %d\n", w, h);
    } else {
        int x = atoi(argv[2]);
        int y = atoi(argv[3]);
        if (x < 0 || y < 0 || x >= w || y >= h) {
            fprintf(stderr, "pnginfo: %d,%d is outside %dx%d\n", x, y, w, h);
            return 1;
        }
        uint32_t p = pixelAt(surface, x, y);
        unsigned a = p >> 24;
        unsigned rgb[3] = {(p >> 16) & 0xff, (p >> 8) & 0xff, p & 0xff};
        for (int i = 0; i < 3; i++)
            rgb[i] = a == 0 ? 0 : (rgb[i] * 255 + a / 2) / a;
        printf("%d %d %u %u %u %u\n", w, h, rgb[0], rgb[1], rgb[2], a);
    }
    plutovg_surface_destroy(surface);
    return 0;
}
