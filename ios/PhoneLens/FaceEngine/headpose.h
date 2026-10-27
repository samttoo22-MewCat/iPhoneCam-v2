#pragma once
#include <opencv2/core.hpp>
#include <vector>

namespace wfd {

/* Head pose (yaw/pitch/roll in degrees) via solvePnP on 6 generic 3D face
 * points: nose tip (from detector kps), chin / eye outer corners / mouth
 * corners (from 106 landmarks; indices verified geometrically on real
 * detections - see docs/STRUCTURE_ANALYSIS.md). */
struct HeadPose {
  float yaw = 0, pitch = 0, roll = 0;
};

class HeadPoseEst {
 public:
  static HeadPose Estimate(const std::vector<cv::Point2f>& lmk,
                           const cv::Point2f kps[5], float img_w, float img_h);
  /* fallback when landmark model is disabled: 5 kps only (synthetic chin) */
  static HeadPose EstimateFromKps(const cv::Point2f kps[5], float img_w,
                                  float img_h);
};

}  // namespace wfd
