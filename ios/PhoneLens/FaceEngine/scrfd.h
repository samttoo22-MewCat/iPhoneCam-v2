#pragma once
#include <opencv2/core.hpp>
#include <vector>
#include "ort_session.h"

namespace wfd {

struct DetBox {
  float rect[4];    /* x1,y1,x2,y2 */
  float score;
  cv::Point2f kps[5];
};

class Scrfd {
 public:
  struct Params {
    float det_thresh = 0.5f;
    float nms_thresh = 0.4f;
    int input_size = 640;
    int max_faces = 10;
  };

  explicit Scrfd(OrtSession* session) : session_(session) {}

  /* returns decoded + nms-filtered boxes */
  std::vector<DetBox> Detect(const cv::Mat& bgr, const Params& p);

  static void Nms(std::vector<DetBox>* boxes, float iou_thresh);

 private:
  OrtSession* session_;
};

}  // namespace wfd
