#include "tracker.h"
#include <algorithm>
#include <cmath>

namespace wfd {

static inline float IoU(const float* a, const float* b) {
  float ix1 = std::max(a[0], b[0]), iy1 = std::max(a[1], b[1]);
  float ix2 = std::min(a[2], b[2]), iy2 = std::min(a[3], b[3]);
  float iw = std::max(0.f, ix2 - ix1), ih = std::max(0.f, iy2 - iy1);
  float inter = iw * ih;
  float aA = (a[2] - a[0]) * (a[3] - a[1]);
  float aB = (b[2] - b[0]) * (b[3] - b[1]);
  return inter / (aA + aB - inter + 1e-9f);
}

static inline float Lerp(float a, float b, float alpha) {
  return a * alpha + b * (1.f - alpha);
}

static float Median(std::vector<float> values) {
  if (values.empty()) return 0.f;
  const size_t middle = values.size() / 2;
  std::nth_element(values.begin(), values.begin() + middle, values.end());
  return values[middle];
}

void FaceTracker::Update(const std::vector<DetBox>& dets,
                         std::vector<TrackState>* tracks_out,
                         std::vector<bool>* need_lmk) {
  tracks_out->clear();
  need_lmk->clear();

  if (!params_.enabled) {
    for (const auto& d : dets) {
      TrackState t;
      t.id = -1;
      t.score = d.score;
      for (int i = 0; i < 4; i++) t.rect[i] = d.rect[i];
      for (int i = 0; i < 5; i++) t.kps[i] = d.kps[i];
      t.landmarks.clear();
      tracks_out->push_back(t);
      need_lmk->push_back(true);
    }
    return;
  }

  /* greedy IoU matching (det sorted by score) */
  std::vector<int> det_to_track(dets.size(), -1);
  std::vector<char> track_matched(tracks_.size(), 0);
  std::vector<std::pair<float, size_t>> order;
  for (size_t i = 0; i < dets.size(); i++)
    order.push_back({-dets[i].score, i});
  std::sort(order.begin(), order.end());

  for (auto& [negs, di] : order) {
    float best = params_.iou_thresh;
    int best_t = -1;
    for (size_t ti = 0; ti < tracks_.size(); ti++) {
      if (track_matched[ti]) continue;
      float v = IoU(dets[di].rect, tracks_[ti].rect);
      if (v > best) {
        best = v;
        best_t = (int)ti;
      }
    }
    if (best_t >= 0) {
      det_to_track[di] = best_t;
      track_matched[best_t] = 1;
    }
  }

  /* update matched tracks */
  for (size_t di = 0; di < dets.size(); di++) {
    int ti = det_to_track[di];
    if (ti < 0) continue;
    TrackState& t = tracks_[ti];
    float a = params_.smooth_alpha;
    for (int i = 0; i < 4; i++) t.rect[i] = Lerp(t.rect[i], dets[di].rect[i], a);
    for (int i = 0; i < 5; i++) {
      t.kps[i].x = Lerp(t.kps[i].x, dets[di].kps[i].x, a);
      t.kps[i].y = Lerp(t.kps[i].y, dets[di].kps[i].y, a);
    }
    t.score = dets[di].score;
    t.hits++;
    t.lost = 0;
  }

  /* age unmatched tracks; drop beyond max_age */
  std::vector<TrackState> kept;
  for (size_t ti = 0; ti < tracks_.size(); ti++) {
    if (!track_matched[ti]) {
      tracks_[ti].lost++;
      if (tracks_[ti].lost > params_.max_age) continue;
    }
    kept.push_back(std::move(tracks_[ti]));
  }
  tracks_ = std::move(kept);

  /* new tracks for unmatched detections */
  for (size_t di = 0; di < dets.size(); di++) {
    if (det_to_track[di] >= 0) continue;
    TrackState t;
    t.id = next_id_++;
    t.score = dets[di].score;
    for (int i = 0; i < 4; i++) t.rect[i] = dets[di].rect[i];
    for (int i = 0; i < 5; i++) t.kps[i] = dets[di].kps[i];
    t.hits = 1;
    tracks_.push_back(std::move(t));
  }

  /* output: tracked faces first (id order), with landmark-refresh hint */
  for (auto& t : tracks_) {
    tracks_out->push_back(t);
    /* refresh landmarks on new tracks, big motion, or every few frames */
    bool big_move = t.hits <= 1;
    bool periodic = (t.hits % 5) == 0;
    bool has = !t.landmarks.empty();
    need_lmk->push_back(!has || big_move || periodic);
  }
}

void FaceTracker::UpdateLandmarks(int id, const std::vector<cv::Point2f>& landmarks) {
  for (auto& track : tracks_) {
    if (track.id == id) {
      track.landmarks = landmarks;
      return;
    }
  }
}

void FaceTracker::UpdateAttributes(int id, int gender, float age_years) {
  for (auto& track : tracks_) {
    if (track.id == id) {
      track.gender = gender;
      track.age_years = age_years;
      return;
    }
  }
}

int FaceTracker::AdvanceOpticalFlow(const cv::Mat& previous_gray, const cv::Mat& gray) {
  if (!params_.enabled || previous_gray.empty() || gray.empty() ||
      previous_gray.size() != gray.size()) return 0;
  int candidates = 0;
  int updated = 0;
  for (auto& track : tracks_) {
    if (track.landmarks.size() < 20) continue;
    candidates++;
    std::vector<cv::Point2f> next;
    std::vector<uchar> status;
    std::vector<float> errors;
    cv::calcOpticalFlowPyrLK(previous_gray, gray, track.landmarks, next, status, errors,
                             cv::Size(21, 21), 3,
                             cv::TermCriteria(cv::TermCriteria::COUNT | cv::TermCriteria::EPS,
                                              20, 0.03));
    std::vector<float> dx, dy;
    std::vector<cv::Point2f> moved = track.landmarks;
    for (size_t i = 0; i < track.landmarks.size(); ++i) {
      if (!status[i] || errors[i] > 20.f || next[i].x < 0 || next[i].y < 0 ||
          next[i].x >= gray.cols || next[i].y >= gray.rows) continue;
      dx.push_back(next[i].x - track.landmarks[i].x);
      dy.push_back(next[i].y - track.landmarks[i].y);
      moved[i] = next[i];
    }
    if (dx.size() < 20) continue;
    const float shift_x = Median(dx), shift_y = Median(dy);
    track.landmarks = std::move(moved);
    for (auto& point : track.kps) { point.x += shift_x; point.y += shift_y; }
    track.rect[0] += shift_x; track.rect[1] += shift_y;
    track.rect[2] += shift_x; track.rect[3] += shift_y;
    updated++;
  }
  return candidates > 0 && updated == 0 ? -1 : updated;
}

std::vector<DetBox> FaceTracker::CurrentDetections() const {
  std::vector<DetBox> dets;
  dets.reserve(tracks_.size());
  for (const auto& track : tracks_) {
    if (track.lost > 0) continue;
    DetBox det;
    det.score = track.score;
    for (int i = 0; i < 4; ++i) det.rect[i] = track.rect[i];
    for (int i = 0; i < 5; ++i) det.kps[i] = track.kps[i];
    dets.push_back(det);
  }
  return dets;
}

}  // namespace wfd
