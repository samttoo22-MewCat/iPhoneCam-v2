#include "headpose.h"
#include <opencv2/calib3d.hpp>
#include <cmath>

namespace wfd {

/* generic 3D face model (mm) in OpenCV camera convention:
 * x right, y DOWN (image y+ down), z into the image. nose tip closest to
 * camera (largest z), eyes above (negative y), chin/mouth below (positive y).
 * (y-negated w.r.t. the classic OpenGL-style model to avoid a reflection) */
static const cv::Point3f k3D[6] = {
    cv::Point3f(0.0f, 0.0f, 0.0f),          /* nose tip */
    cv::Point3f(0.0f, 330.0f, -65.0f),       /* chin */
    cv::Point3f(-225.0f, -170.0f, -135.0f),  /* smaller-x eye outer corner */
    cv::Point3f(225.0f, -170.0f, -135.0f),   /* larger-x eye outer corner */
    cv::Point3f(-150.0f, 150.0f, -125.0f),   /* smaller-x mouth corner */
    cv::Point3f(150.0f, 150.0f, -125.0f),    /* larger-x mouth corner */
};

/* insightface 2d106 landmark indices (verified on real detections) */
enum {
  IDX_CHIN = 0,
  IDX_LEYE_OUT = 35,   /* outer corner, smaller-x side */
  IDX_REYE_OUT = 93,   /* outer corner, larger-x side */
  IDX_LMOUTH = 52,     /* smaller-x mouth corner */
  IDX_RMOUTH = 61,     /* larger-x mouth corner */
};

static HeadPose RotToAngles(const cv::Mat& rvec) {
  cv::Mat R;
  cv::Rodrigues(rvec, R);
  /* R = Rz(roll) * Ry(yaw) * Rx(pitch); LearnOpenCV decomposition:
   * pitch = atan2(R21, R22); yaw = atan2(-R20, sqrt(R10^2+R00^2));
   * roll  = atan2(R10, R00) */
  const double m00 = R.at<double>(0, 0), m10 = R.at<double>(1, 0);
  const double m20 = R.at<double>(2, 0), m21 = R.at<double>(2, 1);
  const double m22 = R.at<double>(2, 2);
  HeadPose hp;
  hp.pitch = (float)(std::atan2(m21, m22) * 180.0 / CV_PI);
  hp.yaw = (float)(std::atan2(-m20, std::sqrt(m10 * m10 + m00 * m00)) * 180.0 /
                   CV_PI);
  hp.roll = (float)(std::atan2(m10, m00) * 180.0 / CV_PI);
  /* keep roll in (-90, 90] to avoid +-180 flips for near-frontal faces */
  if (hp.roll > 90.f) hp.roll -= 180.f;
  if (hp.roll <= -90.f) hp.roll += 180.f;
  return hp;
}

static HeadPose Solve(const std::vector<cv::Point3f>& obj,
                      const std::vector<cv::Point2f>& img, float w, float h) {
  HeadPose hp;
  if (img.size() < 4) return hp;
  float f = std::max(w, h);
  cv::Mat cam = (cv::Mat_<double>(3, 3) << f, 0, w / 2.0, 0, f, h / 2.0, 0, 0,
                1.0);
  std::vector<double> dist;
  cv::Mat rvec, tvec;
  try {
    bool ok = cv::solvePnP(obj, img, cam, dist, rvec, tvec, false,
                           cv::SOLVEPNP_ITERATIVE);
    if (!ok) return hp;
    hp = RotToAngles(rvec);
  } catch (const cv::Exception&) {
  }
  return hp;
}

HeadPose HeadPoseEst::Estimate(const std::vector<cv::Point2f>& lmk,
                              const cv::Point2f kps[5], float img_w,
                              float img_h) {
  if (lmk.size() < 106) return HeadPose();
  /* order x-coordinates so the smaller-x eye/mouth side maps to -225/-150
   * (keeps yaw sign stable regardless of mirror) */
  cv::Point2f leye = lmk[IDX_LEYE_OUT], reye = lmk[IDX_REYE_OUT];
  if (leye.x > reye.x) std::swap(leye, reye);
  cv::Point2f lm = lmk[IDX_LMOUTH], rm = lmk[IDX_RMOUTH];
  if (lm.x > rm.x) std::swap(lm, rm);

  std::vector<cv::Point3f> obj(std::begin(k3D), std::end(k3D));
  std::vector<cv::Point2f> img;
  img.push_back(kps[2]);    /* nose tip (detector) */
  img.push_back(lmk[IDX_CHIN]);
  img.push_back(leye);
  img.push_back(reye);
  img.push_back(lm);
  img.push_back(rm);
  return Solve(obj, img, img_w, img_h);
}

HeadPose HeadPoseEst::EstimateFromKps(const cv::Point2f kps[5], float img_w,
                                      float img_h) {
  cv::Point2f mouth_mid((kps[3].x + kps[4].x) / 2.f,
                        (kps[3].y + kps[4].y) / 2.f);
  const cv::Point2f& nose = kps[2];
  cv::Point2f chin(mouth_mid.x + (mouth_mid.x - nose.x) * 0.35f,
                   mouth_mid.y + (mouth_mid.y - nose.y) * 1.4f);
  cv::Point2f e0 = kps[0], e1 = kps[1];
  if (e0.x > e1.x) std::swap(e0, e1);
  cv::Point2f m0 = kps[3], m1 = kps[4];
  if (m0.x > m1.x) std::swap(m0, m1);
  std::vector<cv::Point3f> obj(std::begin(k3D), std::end(k3D));
  std::vector<cv::Point2f> img;
  img.push_back(nose);
  img.push_back(chin);
  img.push_back(e0);
  img.push_back(e1);
  img.push_back(m0);
  img.push_back(m1);
  return Solve(obj, img, img_w, img_h);
}

}  // namespace wfd
