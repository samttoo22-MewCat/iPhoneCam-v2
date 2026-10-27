#pragma once
#include <opencv2/core.hpp>
#include <vector>
#include "ort_session.h"

namespace wfd {

/* 2D 106-point landmark model (insightface 2d106det). */
class Landmark106 {
 public:
  explicit Landmark106(OrtSession* session) : session_(session) {}
  /* face: rect[4] = x1,y1,x2,y2. Output: 106 points in image coords. */
  std::vector<cv::Point2f> Get(const cv::Mat& bgr, const float* rect);

 private:
  OrtSession* session_;
};

}  // namespace wfd
