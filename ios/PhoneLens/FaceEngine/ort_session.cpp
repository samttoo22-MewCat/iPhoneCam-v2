#include "ort_session.h"

namespace wfd {

OrtSession::OrtSession(int threads) : opts_(Ort::SessionOptions()) {
  env_ = std::make_unique<Ort::Env>(ORT_LOGGING_LEVEL_WARNING, "wfd");
  opts_.SetIntraOpNumThreads(threads > 0 ? threads : 4);
  opts_.SetGraphOptimizationLevel(
      GraphOptimizationLevel::ORT_ENABLE_ALL);
}

bool OrtSession::Load(const std::string& path, std::string* err) {
  try {
    session_ = std::make_unique<Ort::Session>(*env_, path.c_str(), opts_);
  } catch (const Ort::Exception& ex) {
    if (err) *err = ex.what();
    return false;
  }
  Ort::AllocatorWithDefaultOptions alloc;
  auto in_name = session_->GetInputNameAllocated(0, alloc);
  input_name_ = in_name.get();
  auto info = session_->GetInputTypeInfo(0);
  auto shape = info.GetTensorTypeAndShapeInfo().GetShape();
  /* expect NCHW (possibly with dynamic batch) */
  if (shape.size() == 4) {
    in_c_ = (int)shape[1];
    in_h_ = (int)shape[2];
    in_w_ = (int)shape[3];
  } else if (shape.size() == 3) { /* CHW */
    in_c_ = (int)shape[0];
    in_h_ = (int)shape[1];
    in_w_ = (int)shape[2];
  } else {
    if (err) *err = "unexpected input rank: " + std::to_string(shape.size());
    return false;
  }
  output_names_.clear();
  for (size_t i = 0; i < session_->GetOutputCount(); i++) {
    auto name = session_->GetOutputNameAllocated(i, alloc);
    output_names_.push_back(name.get());
  }
  return true;
}

std::vector<const char*> OrtSession::OutputNames() const {
  std::vector<const char*> names;
  for (auto& n : output_names_) names.push_back(n.c_str());
  return names;
}

std::vector<Ort::Value> OrtSession::Run(
    const std::vector<float>& chw, int c, int h, int w,
    const std::vector<const char*>& out_names) {
  std::array<int64_t, 4> shape{1, c, h, w};
  Ort::MemoryInfo mem = Ort::MemoryInfo::CreateCpu(
      OrtAllocatorType::OrtArenaAllocator, OrtMemType::OrtMemTypeDefault);
  auto input = Ort::Value::CreateTensor<float>(
      mem, const_cast<float*>(chw.data()), chw.size(), shape.data(),
      shape.size());
  const char* in_names[] = {input_name_.c_str()};
  return session_->Run(Ort::RunOptions{nullptr}, in_names, &input, 1,
                       out_names.data(), out_names.size());
}

void ToCHW(const cv::Mat& rgb, float mean, float std_,
           std::vector<float>* out) {
  const int H = rgb.rows, W = rgb.cols;
  out->assign((size_t)H * W * 3, 0.f);
  float* pCh0 = out->data();              /* R */
  float* pCh1 = pCh0 + (size_t)H * W;    /* G */
  float* pCh2 = pCh1 + (size_t)H * W;     /* B */
  for (int y = 0; y < H; y++) {
    const uint8_t* row = rgb.ptr<uint8_t>(y);
    for (int x = 0; x < W; x++) {
      const uint8_t* px = row + x * 3;
      pCh0[y * W + x] = ((float)px[0] - mean) / std_;
      pCh1[y * W + x] = ((float)px[1] - mean) / std_;
      pCh2[y * W + x] = ((float)px[2] - mean) / std_;
    }
  }
}

cv::Mat AlignTransform(const cv::Point2f& center, float output_size,
                       float scale) {
  /* mirrors insightface face_align.transform() with rotation=0:
     t1(scale) -> t2(-c*s) -> t4(+S/2)  =>  M = t4 * t2 * t1 */
  double m[6];
  m[0] = scale;
  m[1] = 0;
  m[2] = -center.x * scale + output_size / 2.0;
  m[3] = 0;
  m[4] = scale;
  m[5] = -center.y * scale + output_size / 2.0;
  return cv::Mat(2, 3, CV_64F, m).clone();
}

cv::Mat InvertAffine2x3(const cv::Mat& M) {
  cv::Mat MM = M;
  if (MM.type() != CV_64F) MM.convertTo(MM, CV_64F);
  cv::Mat inv(2, 3, CV_64F);
  double a = MM.at<double>(0, 0), b = MM.at<double>(0, 1);
  double c = MM.at<double>(1, 0), d = MM.at<double>(1, 1);
  double det = a * d - b * c;
  if (std::abs(det) < 1e-12) {
    inv.setTo(0);
    inv.at<double>(0, 0) = 1;
    inv.at<double>(1, 1) = 1;
    return inv;
  }
  double tx = MM.at<double>(0, 2), ty = MM.at<double>(1, 2);
  inv.at<double>(0, 0) = d / det;
  inv.at<double>(0, 1) = -b / det;
  inv.at<double>(1, 0) = -c / det;
  inv.at<double>(1, 1) = a / det;
  inv.at<double>(0, 2) = -(d * tx - b * ty) / det;
  inv.at<double>(1, 2) = -(-c * tx + a * ty) / det;
  return inv;
}

void TransformPoints(const cv::Mat& M, std::vector<cv::Point2f>* pts) {
  cv::Mat MM = M;
  if (MM.type() != CV_32F) MM.convertTo(MM, CV_32F);
  for (auto& p : *pts) {
    float x = MM.at<float>(0, 0) * p.x + MM.at<float>(0, 1) * p.y +
              MM.at<float>(0, 2);
    float y = MM.at<float>(1, 0) * p.x + MM.at<float>(1, 1) * p.y +
              MM.at<float>(1, 2);
    p.x = x;
    p.y = y;
  }
}

}  // namespace wfd
