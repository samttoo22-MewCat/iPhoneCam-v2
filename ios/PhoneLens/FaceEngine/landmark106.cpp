#include "landmark106.h"
#include <cmath>
#include <opencv2/imgproc.hpp>

namespace wfd {

std::vector<cv::Point2f> Landmark106::Get(const cv::Mat& bgr,
                                           const float* rect) {
  std::vector<cv::Point2f> lmk;
  const int S = session_->input_w() > 0 ? session_->input_w() : 192;
  const int num = 106;

  /* insightface Landmark.get(): crop by bbox center,
     scale = S / (max(w,h) * 1.5) */
  float w = rect[2] - rect[0];
  float h = rect[3] - rect[1];
  cv::Point2f center((rect[2] + rect[0]) / 2.f, (rect[3] + rect[1]) / 2.f);
  float scale = (float)S / (std::max(w, h) * 1.5f);
  cv::Mat M = AlignTransform(center, (float)S, scale);
  cv::Mat aimg;
  cv::warpAffine(bgr, aimg, M, cv::Size(S, S));

  /* mean/std: mxnet exports use 0/1, others 127.5/128.
     2d106det from insightface is a mxnet-exported model (find_sub&&find_mul)
     -> mean 0, std 1. */
  cv::Mat rgb;
  cv::cvtColor(aimg, rgb, cv::COLOR_BGR2RGB);
  std::vector<float> chw;
  ToCHW(rgb, 0.f, 1.f, &chw);

  auto outs = session_->Run(chw, 3, S, S, session_->OutputNames());
  if (outs.empty()) return lmk;
  auto shp = outs[0].GetTensorTypeAndShapeInfo().GetShape();
  const float* pred = outs[0].GetTensorData<float>();
  size_t total = 1;
  for (auto d : shp) total *= (size_t)d;

  /* flat [.., 212] -> rows of (x,y) pairs; if more rows than num keep last */
  size_t rows = total / 2;
  size_t start = rows >= (size_t)num ? rows - num : 0;
  const float* src = pred + start * 2;

  lmk.resize(num);
  const int half = S / 2;
  for (int i = 0; i < num; i++) {
    float x = (src[i * 2] + 1.f) * half;
    float y = (src[i * 2 + 1] + 1.f) * half;
    lmk[i] = cv::Point2f(x, y);
  }
  cv::Mat IM = InvertAffine2x3(M);
  TransformPoints(IM, &lmk);
  return lmk;
}

}  // namespace wfd
