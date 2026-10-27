#include "wfd.h"

#include "ort_session.h"
#include "scrfd.h"
#include "landmark106.h"
#include "genderage.h"
#include "headpose.h"
#include "tracker.h"

#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

namespace wfd {

struct EngineImpl {
  wfd_config_t cfg{};
  std::unique_ptr<OrtSession> det_ort;
  std::unique_ptr<OrtSession> lmk_ort;
  std::unique_ptr<OrtSession> attr_ort;
  std::unique_ptr<Scrfd> scrfd;
  std::unique_ptr<Landmark106> lmk;
  std::unique_ptr<GenderAge> attr;
  FaceTracker tracker{FaceTracker::Params{}};
  int frame_seq = 0;
  std::vector<DetBox> last_dets;
  cv::Mat previous_gray;
};

static void ToBGR(const void* pix, wfd_pixfmt_t fmt, int w, int h, int stride,
                  cv::Mat* bgr) {
  if (fmt == WFD_PIXFMT_BGR) {
    cv::Mat tmp(h, w, CV_8UC3, const_cast<void*>(pix), stride);
    *bgr = tmp.clone();
  } else if (fmt == WFD_PIXFMT_RGB) {
    cv::Mat tmp(h, w, CV_8UC3, const_cast<void*>(pix), stride);
    cv::cvtColor(tmp, *bgr, cv::COLOR_RGB2BGR);
  } else if (fmt == WFD_PIXFMT_BGRA || fmt == WFD_PIXFMT_RGBA) {
    cv::Mat tmp(h, w, CV_8UC4, const_cast<void*>(pix), stride);
    cv::cvtColor(tmp, *bgr,
                 fmt == WFD_PIXFMT_BGRA ? cv::COLOR_BGRA2BGR
                                        : cv::COLOR_RGBA2BGR);
  } else if (fmt == WFD_PIXFMT_GRAY) {
    cv::Mat tmp(h, w, CV_8UC1, const_cast<void*>(pix), stride);
    cv::cvtColor(tmp, *bgr, cv::COLOR_GRAY2BGR);
  } else if (fmt == WFD_PIXFMT_NV21 || fmt == WFD_PIXFMT_NV12) {
    cv::Mat tmp(h * 3 / 2, w, CV_8UC1, const_cast<void*>(pix), stride);
    cv::cvtColor(tmp, *bgr, fmt == WFD_PIXFMT_NV21 ? cv::COLOR_YUV2BGR_NV21
                                                   : cv::COLOR_YUV2BGR_NV12);
  } else {
    *bgr = cv::Mat();
  }
}

/* rotate image by 90-degree steps; back maps rotated coords -> original */
static void Rotate90(const cv::Mat& src, int deg, cv::Mat* dst, cv::Mat* back) {
  if (deg == 90) {
    cv::transpose(src, *dst);
    cv::flip(*dst, *dst, 1);
    back->create(2, 3, CV_32F);
    back->at<float>(0, 0) = 0;  back->at<float>(0, 1) = 1;
    back->at<float>(0, 2) = 0;
    back->at<float>(1, 0) = -1; back->at<float>(1, 1) = 0;
    back->at<float>(1, 2) = (float)dst->cols - 1;
  } else if (deg == 180) {
    cv::flip(src, *dst, -1);
    back->create(2, 3, CV_32F);
    back->at<float>(0, 0) = -1; back->at<float>(0, 1) = 0;
    back->at<float>(0, 2) = (float)dst->cols - 1;
    back->at<float>(1, 0) = 0;  back->at<float>(1, 1) = -1;
    back->at<float>(1, 2) = (float)dst->rows - 1;
  } else if (deg == 270) {
    cv::transpose(src, *dst);
    cv::flip(*dst, *dst, 0);
    back->create(2, 3, CV_32F);
    back->at<float>(0, 0) = 0;  back->at<float>(0, 1) = -1;
    back->at<float>(0, 2) = (float)dst->rows - 1;
    back->at<float>(1, 0) = 1;  back->at<float>(1, 1) = 0;
    back->at<float>(1, 2) = 0;
  } else {
    *dst = src;
    back->create(2, 3, CV_32F);
    back->at<float>(0, 0) = 1; back->at<float>(0, 1) = 0;
    back->at<float>(0, 2) = 0;
    back->at<float>(1, 0) = 0; back->at<float>(1, 1) = 1;
    back->at<float>(1, 2) = 0;
  }
}

/* Keep camera preview at its native texture size. Only the analysis pipeline
 * is resized, then result coordinates are mapped back before returning. */
static cv::Mat ResizeForAnalysis(const cv::Mat& source, int max_dimension,
                                 float* scale_x, float* scale_y) {
  *scale_x = 1.f;
  *scale_y = 1.f;
  if (max_dimension <= 0 || std::max(source.cols, source.rows) <= max_dimension) return source;
  const float ratio = (float)max_dimension / (float)std::max(source.cols, source.rows);
  const int width = std::max(2, (int)std::lround(source.cols * ratio));
  const int height = std::max(2, (int)std::lround(source.rows * ratio));
  cv::Mat resized;
  cv::resize(source, resized, cv::Size(width, height), 0, 0, cv::INTER_AREA);
  *scale_x = (float)source.cols / (float)width;
  *scale_y = (float)source.rows / (float)height;
  return resized;
}

static EngineImpl* CreateEngine(const wfd_config_t* cfg) {
  if (!cfg || !cfg->det_model) return nullptr;
  std::string err;
  EngineImpl* e = new EngineImpl();
  e->cfg = *cfg;

  e->det_ort = std::make_unique<OrtSession>(cfg->threads);
  if (!e->det_ort->Load(cfg->det_model, &err)) {
    delete e;
    return nullptr;
  }
  e->scrfd = std::make_unique<Scrfd>(e->det_ort.get());

  if (cfg->lmk_model && cfg->lmk_model[0]) {
    e->lmk_ort = std::make_unique<OrtSession>(cfg->threads);
    if (!e->lmk_ort->Load(cfg->lmk_model, &err)) {
      delete e;
      return nullptr;
    }
    e->lmk = std::make_unique<Landmark106>(e->lmk_ort.get());
  }
  if (cfg->attr_model && cfg->attr_model[0]) {
    e->attr_ort = std::make_unique<OrtSession>(cfg->threads);
    if (!e->attr_ort->Load(cfg->attr_model, &err)) {
      // Attributes are optional. A model/runtime mismatch must not disable
      // detection, landmarks, or the face-anchored beauty path.
      e->attr_ort.reset();
    } else {
      e->attr = std::make_unique<GenderAge>(e->attr_ort.get());
    }
  }

  FaceTracker::Params tp;
  tp.iou_thresh = cfg->track_iou_thresh;
  tp.max_age = cfg->track_max_age;
  tp.smooth_alpha = cfg->smooth_alpha;
  tp.enabled = cfg->track_enabled != 0;
  e->tracker = FaceTracker(tp);
  return e;
}

static int DetectFrame(EngineImpl* impl, const void* pix, wfd_pixfmt_t fmt,
                       int width, int height, int stride, int rotation_deg,
                       wfd_face_t* out_faces, int max_out) {
  if (!impl || !pix || !out_faces || max_out <= 0) return -1;
  int bpp = (fmt == WFD_PIXFMT_GRAY || fmt >= WFD_PIXFMT_NV21)
                ? 1
                : (fmt == WFD_PIXFMT_BGRA || fmt == WFD_PIXFMT_RGBA ? 4 : 3);
  if (stride <= 0 || stride < width * bpp) stride = width * bpp;

  cv::Mat bgr;
  ToBGR(pix, fmt, width, height, stride, &bgr);
  if (bgr.empty()) return -1;

  float analysis_scale_x = 1.f, analysis_scale_y = 1.f;
  cv::Mat analysis_bgr = ResizeForAnalysis(bgr, impl->cfg.analysis_max_dim,
                                           &analysis_scale_x, &analysis_scale_y);

  cv::Mat rot_img, back;
  Rotate90(analysis_bgr, rotation_deg, &rot_img, &back);

  bool run_det = impl->cfg.detect_interval <= 1 ||
                 (impl->frame_seq % impl->cfg.detect_interval) == 0;
  std::vector<DetBox> dets;
  if (!run_det) {
    cv::Mat gray;
    cv::cvtColor(rot_img, gray, cv::COLOR_BGR2GRAY);
    const int optical_result = impl->tracker.AdvanceOpticalFlow(impl->previous_gray, gray);
    if (optical_result < 0) {
      // Fast motion or occlusion invalidated all current points. Do not emit a
      // stale mask: reset and detect this exact newest frame immediately.
      impl->tracker.Reset();
      impl->last_dets.clear();
      run_det = true;
    } else {
      dets = impl->tracker.CurrentDetections();
    }
  }
  if (run_det) {
    Scrfd::Params sp;
    sp.det_thresh = impl->cfg.det_thresh;
    sp.nms_thresh = impl->cfg.nms_thresh;
    sp.input_size = impl->cfg.det_input_size;
    sp.max_faces = impl->cfg.max_faces;
    dets = impl->scrfd->Detect(rot_img, sp);
    impl->last_dets = dets;
  }
  cv::cvtColor(rot_img, impl->previous_gray, cv::COLOR_BGR2GRAY);
  impl->frame_seq++;

  std::vector<TrackState> tracks;
  std::vector<bool> need_lmk;
  impl->tracker.Update(dets, &tracks, &need_lmk);

  int n = 0;
  for (size_t i = 0; i < tracks.size() && n < max_out; i++) {
    TrackState& t = tracks[i];
    // A lost grace-period track is useful for re-association only. It must
    // never drive a visible beauty mask on a newer camera frame.
    if (t.lost > 0) continue;
    if (run_det && need_lmk[i] && impl->lmk) {
      t.landmarks = impl->lmk->Get(rot_img, t.rect);
      impl->tracker.UpdateLandmarks(t.id, t.landmarks);
    }
    wfd_face_t* f = &out_faces[n];
    std::memset(f, 0, sizeof(*f));
    f->track_id = t.id;
    f->score = t.score;
    f->gender = t.gender;
    f->age = t.age_years;
    for (int k = 0; k < 5; k++) f->kps[k] = {t.kps[k].x, t.kps[k].y};
    for (int k = 0; k < 4; k++) f->rect[k] = t.rect[k];
    if (impl->lmk && !t.landmarks.empty() && t.landmarks.size() >= 106) {
      f->num_landmarks = 106;
      for (int k = 0; k < 106; k++)
        f->landmarks[k] = {t.landmarks[k].x, t.landmarks[k].y};
      HeadPose hp = HeadPoseEst::Estimate(t.landmarks, t.kps,
                                                (float)rot_img.cols, (float)rot_img.rows);
      f->yaw = hp.yaw;
      f->pitch = hp.pitch;
      f->roll = hp.roll;
    } else if (impl->lmk == nullptr) {
      HeadPose hp = HeadPoseEst::EstimateFromKps(t.kps, (float)rot_img.cols,
                                                 (float)rot_img.rows);
      f->yaw = hp.yaw;
      f->pitch = hp.pitch;
      f->roll = hp.roll;
    }
    if (impl->attr && (t.hits % 30) == 1) {
      FaceAttr a = impl->attr->Get(rot_img, t.rect);
      t.gender = a.gender;
      t.age_years = a.age;
      impl->tracker.UpdateAttributes(t.id, a.gender, a.age);
      f->gender = a.gender;
      f->age = a.age;
    }
    n++;
  }

  /* map back to original (un-rotated) coordinates */
  for (int i = 0; i < n; i++) {
    wfd_face_t* f = &out_faces[i];
    auto map = [&](float* x, float* y) {
      float rx = *x, ry = *y;
      *x = back.at<float>(0, 0) * rx + back.at<float>(0, 1) * ry +
           back.at<float>(0, 2);
      *y = back.at<float>(1, 0) * rx + back.at<float>(1, 1) * ry +
           back.at<float>(1, 2);
    };
    float x1 = f->rect[0], y1 = f->rect[1], x2 = f->rect[2], y2 = f->rect[3];
    float xs[4] = {x1, x1, x2, x2}, ys[4] = {y1, y2, y1, y2};
    for (int k = 0; k < 4; k++) map(&xs[k], &ys[k]);
    f->rect[0] = std::min(xs[0], xs[1]);
    f->rect[2] = std::max(xs[2], xs[3]);
    f->rect[1] = std::min(ys[0], ys[1]);
    f->rect[3] = std::max(ys[2], ys[3]);
    for (int k = 0; k < 5; k++) map(&f->kps[k].x, &f->kps[k].y);
    for (int k = 0; k < f->num_landmarks; k++)
      map(&f->landmarks[k].x, &f->landmarks[k].y);
    f->rect[0] *= analysis_scale_x; f->rect[2] *= analysis_scale_x;
    f->rect[1] *= analysis_scale_y; f->rect[3] *= analysis_scale_y;
    for (int k = 0; k < 5; k++) {
      f->kps[k].x *= analysis_scale_x;
      f->kps[k].y *= analysis_scale_y;
    }
    for (int k = 0; k < f->num_landmarks; k++) {
      f->landmarks[k].x *= analysis_scale_x;
      f->landmarks[k].y *= analysis_scale_y;
    }
  }
  return n;
}

}  // namespace wfd

/* ---- C API (thin wrappers: no templates allowed inside C linkage) ---- */

extern "C" {

wfd_config_t wfd_default_config(void) {
  wfd_config_t c{};
  c.det_thresh = 0.5f;
  c.nms_thresh = 0.4f;
  c.det_input_size = 640;
  c.max_faces = 10;
  c.threads = 4;
  c.track_enabled = 1;
  c.track_max_age = 30;
  c.track_iou_thresh = 0.3f;
  c.smooth_alpha = 0.6f;
  c.detect_interval = 6;
  c.analysis_max_dim = 720;
  return c;
}

wfd_engine_t* wfd_create(const wfd_config_t* cfg) {
  return (wfd_engine_t*)wfd::CreateEngine(cfg);
}

void wfd_destroy(wfd_engine_t* e) {
  delete (wfd::EngineImpl*)e;
}

void wfd_reset(wfd_engine_t* e) {
  wfd::EngineImpl* impl = (wfd::EngineImpl*)e;
  if (!impl) return;
  impl->tracker.Reset();
  impl->frame_seq = 0;
  impl->last_dets.clear();
}

int wfd_detect(wfd_engine_t* e, const void* pix, wfd_pixfmt_t fmt, int width,
               int height, int stride, int rotation_deg, wfd_face_t* out_faces,
               int max_out) {
  return wfd::DetectFrame((wfd::EngineImpl*)e, pix, fmt, width, height, stride,
                          rotation_deg, out_faces, max_out);
}

const char* wfd_version(void) { return WFD_VERSION; }

}  // extern "C"
