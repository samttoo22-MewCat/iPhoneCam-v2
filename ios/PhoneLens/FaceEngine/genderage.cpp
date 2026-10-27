#include "genderage.h"
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <opencv2/imgproc.hpp>

namespace wfd {

FaceAttr GenderAge::Get(const cv::Mat& bgr, const float* rect) {
  FaceAttr a;
  const int S = session_->input_w() > 0 ? session_->input_w() : 112;

  float w = rect[2] - rect[0];
  float h = rect[3] - rect[1];
  cv::Point2f center((rect[2] + rect[0]) / 2.f, (rect[3] + rect[1]) / 2.f);
  float scale = (float)S / (std::max(w, h) * 1.5f);
  cv::Mat M = AlignTransform(center, (float)S, scale);
  cv::Mat aimg;
  cv::warpAffine(bgr, aimg, M, cv::Size(S, S));

  cv::Mat rgb;
  cv::cvtColor(aimg, rgb, cv::COLOR_BGR2RGB);
  std::vector<float> chw;
  ToCHW(rgb, 127.5f, 128.f, &chw);

  auto outs = session_->Run(chw, 3, S, S, session_->OutputNames());
  if (outs.empty()) return a;
  auto shp = outs[0].GetTensorTypeAndShapeInfo().GetShape();
  const float* pred = outs[0].GetTensorData<float>();
  size_t total = 1;
  for (auto d : shp) total *= (size_t)d;
  if (total < 3) return a;

  /* insightface attribute.py: gender = argmax(pred[:2]); age = pred[2]*100 */
  if (getenv("WFD_DEBUG")) {
    fprintf(stderr, "[wfd] genderage raw: %.4f %.4f %.4f\n", pred[0], pred[1],
            pred[2]);
  }
  a.gender = pred[1] > pred[0] ? 1 : 0; /* 0=female 1=male */
  a.age = pred[2] * 100.f;
  return a;
}

}  // namespace wfd
