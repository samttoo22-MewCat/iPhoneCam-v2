#pragma once
#include "ort_session.h"

namespace wfd {

struct FaceAttr {
  int gender = -1;   /* 0 female, 1 male */
  float age = -1;
};

class GenderAge {
 public:
  explicit GenderAge(OrtSession* session) : session_(session) {}
  FaceAttr Get(const cv::Mat& bgr, const float* rect);

 private:
  OrtSession* session_;
};

}  // namespace wfd
