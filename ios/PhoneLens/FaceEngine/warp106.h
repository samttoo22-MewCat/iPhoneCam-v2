#pragma once
#include <opencv2/core.hpp>
#include <vector>

#include "wfd.h"

namespace wfd {

/* 106-point mesh warp for beauty face reshaping:
 * per-feature landmark displacement -> Delaunay triangulation of the moved
 * points (screen corners pinned for identity outside the face) ->
 * piecewise-affine triangle pairs consumed by the GPU warp pass.
 *
 * Parameter slots (generic beauty-app face controls):
 *  0  a_shoulian     瘦臉 (jaw+cheek inward)
 *  1  a_xiaolian     小臉 (slimmer + slight chin lift)
 *  2  a_smallface    縮小整臉
 *  3  a_dayan        大眼 (eye region dilate)
 *  4  a_xiaotou      小頭 (stronger global shrink)
 *  5  a_shoubi      瘦鼻 (nose walls inward)
 *  6  a_zuixing      嘴型 (mouth corners narrow+lift)
 *  7  a_quangu       颧骨 (cheekbones inward+up)
 *  8  a_xiaba        下巴 (chin up)
 *  9  a_shoue        瘦額 (upper temple inward)
 * 10  a_yanju        眼距 (inner corners toward nose)
 * 11  a_yanjiao      眼角 (outer corners lift)
 * 12  a_biyi         鼻翼 (nostril walls inward, strong)
 * 13  a_changbi      長鼻 (nose tip down)
 * 14  a_renzhong     人中 (upper lip up)
 * 15  a_changtui     長腿 (body-only slot; no-op in face warp)
 * 16  a_duduchun     嘟嘟唇 (mouth ring dilate)
 * 17  a_xiahexian    下頜線 (lower jaw tighten)
 * 18  a_toubaolian   頭包臉 (temple out, jaw in)
 * 19  a_shangen      鼻根 (bridge top pinch)
 */

/* 12 floats per triangle: src uv x3, dst uv x3 (uv 0..1, y down). */
int ComputeWarp106(const wfd_point_t* lmk, int num, const float* params,
                   int n_params, float img_w, float img_h, float* out_tris,
                   int max_tris);

/* [0]=EAR left, [1]=EAR right, [2]=mouth open ratio, [3]=brow raise ratio */
int Expression106(const wfd_point_t* lmk, int num, float* out4);

}  // namespace wfd
