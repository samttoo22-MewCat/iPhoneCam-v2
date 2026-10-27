#include "scrfd.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <opencv2/imgproc.hpp>
#include <opencv2/imgproc.hpp>

namespace wfd {

static inline float IoU(const float* a, const float* b) {
  float ix1 = std::max(a[0], b[0]), iy1 = std::max(a[1], b[1]);
  float ix2 = std::min(a[2], b[2]), iy2 = std::min(a[3], b[3]);
  float iw = std::max(0.f, ix2 - ix1), ih = std::max(0.f, iy2 - iy1);
  float inter = iw * ih;
  float areaA = (a[2] - a[0]) * (a[3] - a[1]);
  float areaB = (b[2] - b[0]) * (b[3] - b[1]);
  return inter / (areaA + areaB - inter + 1e-9f);
}

void Scrfd::Nms(std::vector<DetBox>* boxes, float iou_thresh) {
  std::sort(boxes->begin(), boxes->end(),
            [](const DetBox& a, const DetBox& b) { return a.score > b.score; });
  std::vector<DetBox> keep;
  for (size_t i = 0; i < boxes->size(); i++) {
    bool suppressed = false;
    for (size_t j = 0; j < keep.size(); j++) {
      if (IoU((*boxes)[i].rect, keep[j].rect) > iou_thresh) {
        suppressed = true;
        break;
      }
    }
    if (!suppressed) keep.push_back((*boxes)[i]);
  }
  *boxes = keep;
}

std::vector<DetBox> Scrfd::Detect(const cv::Mat& bgr, const Params& p) {
  std::vector<DetBox> out;
  const int S = p.input_size; /* 640 for det_10g */

  /* insightface-style: aspect-preserving resize + pad to square */
  float ratio = (float)bgr.rows / (float)bgr.cols;
  int new_w, new_h;
  if (ratio > 1.f) {
    new_h = S;
    new_w = (int)(S / ratio) & ~1;
  } else {
    new_w = S;
    new_h = (int)(S * ratio) & ~1;
  }
  cv::Mat resized, det_im;
  cv::resize(bgr, resized, cv::Size(new_w, new_h));
  det_im = cv::Mat::zeros(S, S, CV_8UC3);
  resized.copyTo(det_im(cv::Rect(0, 0, new_w, new_h)));

  cv::Mat rgb;
  cv::cvtColor(det_im, rgb, cv::COLOR_BGR2RGB);
  std::vector<float> chw;
  ToCHW(rgb, 127.5f, 128.f, &chw);

  auto outs = session_->Run(chw, 3, S, S, session_->OutputNames());

  /* Classify outputs by last-dim: 1=score, 4=bbox, 10=kps.
     Pair score/bbox/kps of the same stride by row count:
     rows = (S/stride)^2 * anchors(2). */
  struct Arr { const float* data; int rows; };
  std::vector<Arr> scores, bboxes, kpss;
  for (auto& v : outs) {
    auto shp = v.GetTensorTypeAndShapeInfo().GetShape();
    /* outputs may be (N,C) or (1,N,C) */
    if (shp.size() != 2 && shp.size() != 3) continue;
    int rows = (int)(shp.size() == 3 ? shp[1] : shp[0]);
    int ch = (int)shp.back();
    Arr a{v.GetTensorData<float>(), rows};
    if (ch == 1) scores.push_back(a);
    else if (ch == 4) bboxes.push_back(a);
    else if (ch == 10) kpss.push_back(a);
  }

  std::vector<DetBox> cands;
  for (auto& sc : scores) {
    if (getenv("WFD_DEBUG"))
      fprintf(stderr, "[wfd] level rows=%d -> %zu cands (sofar)\n", sc.rows,
              cands.size());
    /* stride from rows: rows = (S/stride)^2 * 2 */
    int cell = sc.rows / 2;
    int fmap = (int)std::round(std::sqrt((double)cell));
    if (fmap <= 0 || fmap * fmap != cell) continue;
    int stride = S / fmap;
    if (stride * fmap != S) continue;

    /* find bbox/kps array with same row count */
    const Arr* bb = nullptr;
    const Arr* kk = nullptr;
    for (auto& b : bboxes) if (b.rows == sc.rows) { bb = &b; break; }
    for (auto& k : kpss) if (k.rows == sc.rows) { kk = &k; break; }
    if (!bb || !kk) continue;

    for (int r = 0; r < sc.rows; r++) {
      /* model already applies sigmoid: values are probabilities */
      float conf = sc.data[r];
      if (conf < p.det_thresh) continue;
      /* insightface: both anchors share the cell center (integer*stride) */
      int cell_idx = r / 2;
      float cx = (float)((cell_idx % fmap) * stride);
      float cy = (float)((cell_idx / fmap) * stride);
      const float* bp = bb->data + (size_t)r * 4;
      DetBox db;
      db.score = conf;
      db.rect[0] = cx - bp[0] * stride;
      db.rect[1] = cy - bp[1] * stride;
      db.rect[2] = cx + bp[2] * stride;
      db.rect[3] = cy + bp[3] * stride;
      const float* kp = kk->data + (size_t)r * 10;
      for (int k = 0; k < 5; k++) {
        db.kps[k].x = cx + kp[k * 2] * stride;
        db.kps[k].y = cy + kp[k * 2 + 1] * stride;
      }
      cands.push_back(db);
    }
  }

  if (getenv("WFD_DEBUG"))
    fprintf(stderr, "[wfd] img=%dx%d det_canvas=%dx%d cands=%zu\n",
            bgr.cols, bgr.rows, new_w, new_h, cands.size());
  Nms(&cands, p.nms_thresh);

  float sx = (float)bgr.cols / new_w;
  float sy = (float)bgr.rows / new_h;
  for (auto& c : cands) {
    if (p.max_faces > 0 && (int)out.size() >= p.max_faces) break;
    for (int i = 0; i < 4; i += 2) { c.rect[i] *= sx; c.rect[i + 1] *= sy; }
    for (auto& k : c.kps) { k.x *= sx; k.y *= sy; }
    out.push_back(c);
  }
  return out;
}

}  // namespace wfd
