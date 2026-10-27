#pragma once
#include <opencv2/core.hpp>
#include <opencv2/video/tracking.hpp>
#include <vector>
#include "scrfd.h"

namespace wfd {

/* IoU-matching face tracker with EMA smoothing: stable face ids across
 * frames, temporal smoothing, lost-track grace period (face "lock"). */
struct TrackState {
  int id = -1;
  int lost = 0;           /* frames since last detection match */
  int hits = 0;           /* total matched detections */
  float rect[4]{};
  cv::Point2f kps[5];
  std::vector<cv::Point2f> landmarks; /* 106 or empty */
  float score = 0;
  int gender = -1;   /* 0 female, 1 male, -1 unknown */
  float age_years = -1; /* estimated age, -1 unknown */
};

class FaceTracker {
 public:
  struct Params {
    float iou_thresh = 0.3f;
    int max_age = 30;
    float smooth_alpha = 0.6f; /* weight of history (higher = smoother) */
    bool enabled = true;
  };

  explicit FaceTracker(const Params& p) : params_(p) {}

  /* Update with per-frame detections; returns tracks in display order.
   * out_lmk_ready[i]: whether caller should run landmark model for that
   * track (new or big move) - cached otherwise. */
  void Update(const std::vector<DetBox>& dets,
              std::vector<TrackState>* tracks_out,
              std::vector<bool>* need_lmk);

  void Reset() { tracks_.clear(); next_id_ = 1; }
  void UpdateLandmarks(int id, const std::vector<cv::Point2f>& landmarks);
  void UpdateAttributes(int id, int gender, float age_years);
  // Returns -1 when existing tracks all lose KLT validation, 0 when there is
  // nothing to advance, or the number of tracks advanced successfully.
  int AdvanceOpticalFlow(const cv::Mat& previous_gray, const cv::Mat& gray);
  std::vector<DetBox> CurrentDetections() const;
  std::vector<TrackState>& tracks() { return tracks_; }

 private:
  std::vector<TrackState> tracks_;
  int next_id_ = 1;
  Params params_;
};

}  // namespace wfd
