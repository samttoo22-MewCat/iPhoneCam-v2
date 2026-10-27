#pragma once
#include <onnxruntime_cxx_api.h>
#include <opencv2/core.hpp>
#include <memory>
#include <string>
#include <vector>

namespace wfd {

/* Thin wrapper around an Ort::Session: owns env, memory info, io names. */
class OrtSession {
 public:
  OrtSession(int threads);
  bool Load(const std::string& path, std::string* err = nullptr);

  /* input info */
  std::string input_name() const { return input_name_; }
  int input_h() const { return in_h_; }
  int input_w() const { return in_w_; }
  int input_c() const { return in_c_; }

  /* Run with one float input (CHW, RGB, preprocessed). Returns output
   * tensors. c/h/w are explicit because models may have dynamic input. */
  std::vector<Ort::Value> Run(const std::vector<float>& chw, int c, int h,
                              int w,
                              const std::vector<const char*>& out_names);

  size_t output_count() const { return output_names_.size(); }
  std::string output_name(size_t i) const { return output_names_[i]; }
  std::vector<const char*> OutputNames() const;

  Ort::Env* env() { return env_.get(); }

 private:
  std::unique_ptr<Ort::Env> env_;
  Ort::SessionOptions opts_;
  std::unique_ptr<Ort::Session> session_;
  std::string input_name_;
  std::vector<std::string> output_names_;
  int in_c_ = 3, in_h_ = 0, in_w_ = 0;
};

/* Convert an 8UC3 RGB cv::Mat to CHW float: (v - mean) / std */
void ToCHW(const cv::Mat& rgb, float mean, float std_, std::vector<float>* out);

/* similarity transform used by insightface face_align.transform() */
cv::Mat AlignTransform(const cv::Point2f& center, float output_size, float scale);
cv::Mat InvertAffine2x3(const cv::Mat& M);
void TransformPoints(const cv::Mat& M, std::vector<cv::Point2f>* pts);

}  // namespace wfd
