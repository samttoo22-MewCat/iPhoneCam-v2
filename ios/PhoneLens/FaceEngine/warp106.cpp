#include "warp106.h"

#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <map>
#include <utility>

namespace wfd {

/* ---- 2d106 landmark index groups (verified geometrically on real faces) ---- */
enum {
  IDX_CHIN = 0,
  IDX_TEMPLE_L = 1,
  IDX_TEMPLE_R = 17,
  IDX_CHEEK_L0 = 9,   IDX_CHEEK_L1 = 16,   // left upper cheek line
  IDX_JAW_L0 = 2,     IDX_JAW_L1 = 8,      // left jawline -> chin
  IDX_JAW_R0 = 18,    IDX_JAW_R1 = 24,     // right jawline -> chin
  IDX_CHEEK_R0 = 25,  IDX_CHEEK_R1 = 32,   // right upper cheek line
  IDX_EYE_L0 = 33,    IDX_EYE_L1 = 42,     // left eye ring (35 outer, 39 inner)
  IDX_EYE_R0 = 87,    IDX_EYE_R1 = 96,     // right eye ring (93 outer, 89 inner)
  IDX_EYE_L_OUT = 35, IDX_EYE_L_IN = 39,
  IDX_EYE_R_IN = 89,  IDX_EYE_R_OUT = 93,
  IDX_BROW_L0 = 43,   IDX_BROW_L1 = 51,
  IDX_BROW_R0 = 97,   IDX_BROW_R1 = 105,
  IDX_NOSE_BRIDGE_L = 72, IDX_NOSE_BRIDGE_R = 81,
  IDX_NOSE_TIP = 86,
  IDX_NOSTRIL_L0 = 76, IDX_NOSTRIL_L1 = 77,
  IDX_NOSTRIL_R0 = 84, IDX_NOSTRIL_R1 = 85,
  IDX_NOSE_BOTTOM0 = 78, IDX_NOSE_BOTTOM1 = 80,
  IDX_MOUTH_L = 52,   IDX_MOUTH_R = 61,
  IDX_MOUTH_RING0 = 52, IDX_MOUTH_RING1 = 71,  // full outer+inner ring
};

struct Geom {
  float axisX;        // vertical reference through the nose
  float eyeMidX, eyeMidY;
  float faceW, faceH; // rough face extents
  cv::Point2f mouthMid;
};

static Geom Measure(const cv::Point2f* p) {
  Geom g{};
  g.axisX = p[IDX_NOSE_TIP].x;
  float eyeMidXL = (p[IDX_EYE_L_IN].x + p[IDX_EYE_L_OUT].x) * 0.5f;
  float eyeMidXR = (p[IDX_EYE_R_IN].x + p[IDX_EYE_R_OUT].x) * 0.5f;
  float eyeMidYL = (p[IDX_EYE_L_IN].y + p[IDX_EYE_L_OUT].y) * 0.5f;
  float eyeMidYR = (p[IDX_EYE_R_IN].y + p[IDX_EYE_R_OUT].y) * 0.5f;
  g.eyeMidX = (eyeMidXL + eyeMidXR) * 0.5f;
  g.eyeMidY = (eyeMidYL + eyeMidYR) * 0.5f;
  g.faceW = std::abs(p[IDX_EYE_R_OUT].x - p[IDX_EYE_L_OUT].x) * 2.4f;
  g.faceH = std::abs(p[IDX_CHIN].y - g.eyeMidY) * 1.35f;
  g.mouthMid = (p[IDX_MOUTH_L] + p[IDX_MOUTH_R]) * 0.5f;
  return g;
}

/* move a point toward the vertical face axis (horizontal only) */
static inline void TowardAxis(cv::Point2f* p, int idx, const Geom& g,
                              float k, float yLift = 0.f) {
  p[idx].x += (g.axisX - p[idx].x) * k;
  p[idx].y -= yLift;
}

/* displace a set of ring points away from / toward a center (dilate/contract) */
static void Radial(cv::Point2f* p, const int* ids, int n, cv::Point2f c,
                   float factor) {
  for (int i = 0; i < n; i++) {
    cv::Point2f& q = p[ids[i]];
    q = c + (q - c) * factor;
  }
}

int ComputeWarp106(const wfd_point_t* lmk, int num, const float* params,
                   int n_params, float img_w, float img_h, float* out_tris,
                   int max_tris) {
  if (!lmk || num < 106 || !params || !out_tris || max_tris <= 0) return 0;
  float prm[20] = {0};
  for (int i = 0; i < 20 && i < n_params; i++) {
    prm[i] = std::min(1.f, std::max(0.f, params[i]));
  }

  const float W = img_w > 1 ? img_w : 640.f;
  const float H = img_h > 1 ? img_h : 480.f;

  /* Landmark regressors may overshoot by a fraction of a pixel. Subdiv2D
   * rejects out-of-bounds vertices, so clamp the mesh domain up front. */
  auto InBounds = [W, H](cv::Point2f p) {
    constexpr float kInset = 0.01f;
    p.x = std::min(W - kInset, std::max(kInset, p.x));
    p.y = std::min(H - kInset, std::max(kInset, p.y));
    return p;
  };
  cv::Point2f src[106];
  for (int i = 0; i < 106; i++) src[i] = InBounds(cv::Point2f(lmk[i].x, lmk[i].y));
  cv::Point2f dst[110];  // 106 face + 4 pinned screen corners
  for (int i = 0; i < 106; i++) dst[i] = src[i];

  const Geom g = Measure(src);
  const float* k = prm;

  /* --- face slimming family ------------------------------------------ */
  if (k[0] > 0 || k[1] > 0 || k[7] > 0 || k[17] > 0 || k[18] > 0) {
    float wJaw = 0.32f * k[0] + 0.42f * k[1] + 0.40f * k[17];
    float wCheek = 0.18f * k[0] + 0.24f * k[1];
    for (int i = IDX_JAW_L0; i <= IDX_JAW_L1; i++) TowardAxis(dst, i, g, wJaw);
    for (int i = IDX_JAW_R0; i <= IDX_JAW_R1; i++) TowardAxis(dst, i, g, wJaw);
    for (int i = IDX_CHEEK_L0; i <= IDX_CHEEK_L1; i++) TowardAxis(dst, i, g, wCheek);
    for (int i = IDX_CHEEK_R0; i <= IDX_CHEEK_R1; i++) TowardAxis(dst, i, g, wCheek);
    if (k[1] > 0) dst[IDX_CHIN].y -= g.faceH * 0.03f * k[1];
  }
  if (k[7] > 0) {  // cheekbones: upper cheek in + up
    float w = 0.30f * k[7];
    for (int i = IDX_CHEEK_L0; i <= IDX_CHEEK_L1; i++) {
      TowardAxis(dst, i, g, w, g.faceH * 0.02f * k[7]);
    }
    for (int i = IDX_CHEEK_R0; i <= IDX_CHEEK_R1; i++) {
      TowardAxis(dst, i, g, w, g.faceH * 0.02f * k[7]);
    }
  }
  if (k[17] > 0) {  // jawline extra tighten + slight lift
    float w = 0.26f * k[17];
    for (int i = IDX_JAW_L0; i <= IDX_JAW_L1; i++)
      TowardAxis(dst, i, g, 0.f, g.faceH * 0.02f * k[17]);
    TowardAxis(dst, IDX_CHIN, g, 0.f, g.faceH * 0.03f * k[17]);
    (void)w;
  }
  if (k[18] > 0) {  // toubaolian: temples out, jaw in
    float t = 0.14f * k[18];
    dst[IDX_TEMPLE_L].x -= g.faceW * t * 0.5f;
    dst[IDX_TEMPLE_R].x += g.faceW * t * 0.5f;
    float wj = 0.18f * k[18];
    for (int i = IDX_CHEEK_L0; i <= IDX_CHEEK_L1; i++) TowardAxis(dst, i, g, wj);
    for (int i = IDX_CHEEK_R0; i <= IDX_CHEEK_R1; i++) TowardAxis(dst, i, g, wj);
  }

  /* --- whole face / head shrink ---------------------------------------- */
  if (k[2] > 0 || k[4] > 0) {
    float s = 1.f - (0.10f * k[2] + 0.16f * k[4]);
    cv::Point2f c(g.eyeMidX, g.eyeMidY + g.faceH * 0.18f);
    for (int i = 0; i < 106; i++) dst[i] = c + (dst[i] - c) * s;
  }

  /* --- eyes ------------------------------------------------------------ */
  if (k[3] > 0) {
    int eyeL[10], eyeR[10];
    for (int i = 0; i < 10; i++) {
      eyeL[i] = IDX_EYE_L0 + i;
      eyeR[i] = IDX_EYE_R0 + i;
    }
    cv::Point2f cL = (src[IDX_EYE_L_IN] + src[IDX_EYE_L_OUT]) * 0.5f;
    cv::Point2f cR = (src[IDX_EYE_R_IN] + src[IDX_EYE_R_OUT]) * 0.5f;
    Radial(dst, eyeL, 10, cL, 1.f + 0.22f * k[3]);
    Radial(dst, eyeR, 10, cR, 1.f + 0.22f * k[3]);
  }
  if (k[10] > 0) {  // eye distance: inner corners toward the nose
    float iod = std::abs(src[IDX_EYE_R_IN].x - src[IDX_EYE_L_IN].x);
    float d = iod * 0.10f * k[10];
    dst[IDX_EYE_L_IN].x += d * 0.5f;
    dst[IDX_EYE_R_IN].x -= d * 0.5f;
  }
  if (k[11] > 0) {  // outer eye corners lift
    float lift = g.faceH * 0.035f * k[11];
    dst[IDX_EYE_L_OUT].y -= lift;
    dst[IDX_EYE_R_OUT].y -= lift;
  }

  /* --- nose ------------------------------------------------------------ */
  if (k[5] > 0 || k[12] > 0) {
    float wall = 0.22f * k[5] + 0.30f * k[12];
    int walls[] = {IDX_NOSTRIL_L0, IDX_NOSTRIL_L1, IDX_NOSTRIL_R0, IDX_NOSTRIL_R1};
    for (int id : walls) TowardAxis(dst, id, g, wall);
    int bottom[] = {IDX_NOSE_BOTTOM0, IDX_NOSE_BOTTOM1};
    for (int id : bottom) TowardAxis(dst, id, g, wall * 0.7f);
  }
  if (k[13] > 0) {  // longer nose: tip/bottom down
    float down = g.faceH * 0.035f * k[13];
    dst[IDX_NOSE_TIP].y += down;
    for (int id = IDX_NOSE_BOTTOM0; id <= IDX_NOSE_BOTTOM1; id++) dst[id].y += down;
  }
  if (k[19] > 0) {  // nose root pinch
    float iod = std::abs(src[IDX_EYE_R_IN].x - src[IDX_EYE_L_IN].x);
    float d = iod * 0.07f * k[19];
    dst[IDX_NOSE_BRIDGE_L].x += d;
    dst[IDX_NOSE_BRIDGE_R].x -= d;
  }

  /* --- mouth ----------------------------------------------------------- */
  if (k[6] > 0) {  // mouth shape: corners narrow + slight lift
    float half = std::abs(src[IDX_MOUTH_R].x - src[IDX_MOUTH_L].x) * 0.5f;
    float in = half * 0.16f * k[6];
    dst[IDX_MOUTH_L].x += in;
    dst[IDX_MOUTH_R].x -= in;
    dst[IDX_MOUTH_L].y -= g.faceH * 0.012f * k[6];
    dst[IDX_MOUTH_R].y -= g.faceH * 0.012f * k[6];
  }
  if (k[14] > 0) {  // philtrum: upper lip up
    float up = g.faceH * 0.03f * k[14];
    int upper[] = {63, 64, 65, 67, 68, 69, 71};
    for (int id : upper) dst[id].y -= up;
  }
  if (k[16] > 0) {  // plump lips: ring dilate
    int ring[20];
    for (int i = 0; i < 20; i++) ring[i] = IDX_MOUTH_RING0 + i;
    Radial(dst, ring, 20, g.mouthMid, 1.f + 0.16f * k[16]);
  }

  /* chin lift (xiaba) after shrink so it is not overwritten */
  if (k[8] > 0) {
    float up = g.faceH * 0.05f * k[8];
    dst[IDX_CHIN].y -= up;
    int nearChin[] = {7, 8, 18, 19};
    for (int id : nearChin) dst[id].y -= up * 0.5f;
  }
  if (k[9] > 0) {  // narrower forehead
    float w = 0.16f * k[9];
    int upper[] = {IDX_CHEEK_L0, IDX_CHEEK_L0 + 1, IDX_CHEEK_L0 + 2,
                   IDX_CHEEK_L0 + 3, IDX_CHEEK_R0, IDX_CHEEK_R0 + 1,
                   IDX_CHEEK_R0 + 2, IDX_CHEEK_R0 + 3};
    for (int id : upper) TowardAxis(dst, id, g, w);
  }

  /* --- triangulate moved points (+4 pinned corners) -------------------- */
  cv::Point2f all[110];
  for (int i = 0; i < 106; i++) all[i] = InBounds(dst[i]);
  all[106] = cv::Point2f(0.01f, 0.01f);
  all[107] = cv::Point2f(W - 0.01f, 0.01f);
  all[108] = cv::Point2f(0.01f, H - 0.01f);
  all[109] = cv::Point2f(W - 0.01f, H - 0.01f);
  cv::Point2f srcAll[110];
  for (int i = 0; i < 106; i++) srcAll[i] = src[i];
  srcAll[106] = all[106]; srcAll[107] = all[107];
  srcAll[108] = all[108]; srcAll[109] = all[109];

  cv::Subdiv2D subdiv(cv::Rect(0, 0, (int)W, (int)H));
  std::map<std::pair<int, int>, int> coordIndex;
  for (int i = 0; i < 110; i++) {
    subdiv.insert(all[i]);
    coordIndex[{(int)std::lround(all[i].x * 8.f),
                (int)std::lround(all[i].y * 8.f)}] = i;
  }
  std::vector<cv::Vec6f> tris;
  subdiv.getTriangleList(tris);

  int n = 0;
  for (const auto& t : tris) {
    int idx[3];
    bool ok = true;
    for (int j = 0; j < 3; j++) {
      auto key = std::make_pair((int)std::lround(t[j * 2] * 8.f),
                                (int)std::lround(t[j * 2 + 1] * 8.f));
      auto it = coordIndex.find(key);
      if (it == coordIndex.end()) { ok = false; break; }
      idx[j] = it->second;
    }
    if (!ok) continue;
    const cv::Point2f& s0 = srcAll[idx[0]];
    const cv::Point2f& s1 = srcAll[idx[1]];
    const cv::Point2f& s2 = srcAll[idx[2]];
    const cv::Point2f& d0 = all[idx[0]];
    const cv::Point2f& d1 = all[idx[1]];
    const cv::Point2f& d2 = all[idx[2]];
    const float sourceArea = (s1.x - s0.x) * (s2.y - s0.y) -
                             (s1.y - s0.y) * (s2.x - s0.x);
    const float destArea = (d1.x - d0.x) * (d2.y - d0.y) -
                           (d1.y - d0.y) * (d2.x - d0.x);
    /* A folded triangle would sample the face backwards. Omit it so the
     * renderer keeps the untouched camera texture underneath that tiny area. */
    if (std::abs(sourceArea) < 0.01f || std::abs(destArea) < 0.01f ||
        ((sourceArea > 0.f) != (destArea > 0.f))) continue;
    if (n >= max_tris) break;
    float* o = out_tris + (size_t)n * 12;
    for (int j = 0; j < 3; j++) {
      o[j * 2] = srcAll[idx[j]].x / W;
      o[j * 2 + 1] = srcAll[idx[j]].y / H;
      o[6 + j * 2] = all[idx[j]].x / W;
      o[6 + j * 2 + 1] = all[idx[j]].y / H;
    }
    n++;
  }
  return n;
}

int Expression106(const wfd_point_t* lmk, int num, float* out4) {
  if (!lmk || num < 106 || !out4) return -1;
  cv::Point2f p[106];
  for (int i = 0; i < 106; i++) p[i] = cv::Point2f(lmk[i].x, lmk[i].y);

  auto extent = [&](int a, int b) -> std::pair<float, float> {
    float mnx = 1e9f, mxx = -1e9f, mny = 1e9f, mxy = -1e9f;
    for (int i = a; i <= b; i++) {
      mnx = std::min(mnx, p[i].x); mxx = std::max(mxx, p[i].x);
      mny = std::min(mny, p[i].y); mxy = std::max(mxy, p[i].y);
    }
    return {mxx - mnx, mxy - mny};
  };

  auto eye = [&](int a, int b) {
    auto e = extent(a, b);
    return e.first > 1.f ? e.second / e.first : 1.f;
  };
  out4[0] = eye(IDX_EYE_L0, IDX_EYE_L1);
  out4[1] = eye(IDX_EYE_R0, IDX_EYE_R1);
  auto mouth = extent(IDX_MOUTH_RING0, IDX_MOUTH_RING1);
  out4[2] = mouth.first > 1.f ? mouth.second / mouth.first : 0.f;
  float browTopL = 1e9f, browTopR = 1e9f, eyeTopL = 1e9f, eyeTopR = 1e9f;
  for (int i = IDX_BROW_L0; i <= IDX_BROW_L1; i++) browTopL = std::min(browTopL, p[i].y);
  for (int i = IDX_BROW_R0; i <= IDX_BROW_R1; i++) browTopR = std::min(browTopR, p[i].y);
  for (int i = IDX_EYE_L0; i <= IDX_EYE_L1; i++) eyeTopL = std::min(eyeTopL, p[i].y);
  for (int i = IDX_EYE_R0; i <= IDX_EYE_R1; i++) eyeTopR = std::min(eyeTopR, p[i].y);
  float faceH = std::abs(p[IDX_CHIN].y - (eyeTopL + eyeTopR) * 0.5f);
  out4[3] = faceH > 1.f ? (((eyeTopL + eyeTopR) - (browTopL + browTopR))) /
                              (2.f * faceH) + 0.5f
                        : 0.5f;
  return 0;
}

}  // namespace wfd

/* ---- C API (thin wrappers, no templates under C linkage) ---- */
extern "C" {

int wfd_warp106(const wfd_point_t* lmk, int num, const float* params,
                int n_params, float img_w, float img_h, float* out_tris,
                int max_tris) {
  return wfd::ComputeWarp106(lmk, num, params, n_params, img_w, img_h, out_tris,
                            max_tris);
}

int wfd_expression(const wfd_point_t* lmk, int num, float* out4) {
  return wfd::Expression106(lmk, num, out4);
}

}  // extern "C"
