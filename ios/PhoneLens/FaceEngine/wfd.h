#ifndef WFD_H
#define WFD_H

#ifdef __cplusplus
extern "C" {
#endif

#define WFD_MAX_LANDMARKS 128
#define WFD_VERSION "1.0.0"

typedef struct { float x, y; } wfd_point_t;

typedef enum {
  WFD_PIXFMT_BGR = 0,
  WFD_PIXFMT_RGB,
  WFD_PIXFMT_BGRA,
  WFD_PIXFMT_RGBA,
  WFD_PIXFMT_GRAY,
  WFD_PIXFMT_NV21,
  WFD_PIXFMT_NV12,
} wfd_pixfmt_t;

typedef struct {
  int track_id;      /* stable id across frames, -1 if tracking disabled */
  float score;       /* detector confidence [0,1] */
  float rect[4];     /* x1,y1,x2,y2 in original image coords */
  wfd_point_t kps[5];/* eyes(0,1), nose(2), mouth corners(3,4) */
  int num_landmarks;      /* 106 when landmark model enabled, else 0 */
  wfd_point_t landmarks[WFD_MAX_LANDMARKS];
  float yaw, pitch, roll; /* degrees */
  int gender;             /* 0=female 1=male -1=unknown */
  float age;              /* years, -1 unknown */
} wfd_face_t;

typedef struct {
  const char* det_model;   /* SCRFD onnx (required) */
  const char* lmk_model;   /* 2d106det onnx (NULL -> no landmarks) */
  const char* attr_model;  /* genderage onnx (NULL -> no attributes) */
  float det_thresh;        /* default 0.5 */
  float nms_thresh;        /* default 0.4 */
  int   det_input_size;    /* detector square input, default 640 */
  int   max_faces;         /* default 10 */
  int   threads;           /* onnxruntime intra-op threads, default 4 */
  int   track_enabled;     /* 1 -> assign stable ids + smoothing */
  int   track_max_age;     /* frames a lost track survives, default 30 */
  float track_iou_thresh;  /* match threshold, default 0.3 */
  float smooth_alpha;      /* EMA factor for box/kps/landmarks, 0..1, default 0.6 */
  int   detect_interval;   /* run detector every N frames (>=1), default 1 */
  int   analysis_max_dim;  /* downsample analysis only; 0 keeps source size */
} wfd_config_t;

typedef struct wfd_engine wfd_engine_t;

wfd_config_t wfd_default_config(void);
wfd_engine_t* wfd_create(const wfd_config_t* cfg);
void wfd_destroy(wfd_engine_t* e);

/* rotation_deg: 0/90/180/270 clockwise rotation of the input buffer. */
int  wfd_detect(wfd_engine_t* e, const void* pix, wfd_pixfmt_t fmt,
                int width, int height, int stride, int rotation_deg,
                wfd_face_t* out_faces, int max_out);

void wfd_reset(wfd_engine_t* e);   /* clear all tracks */
const char* wfd_version(void);

/* 106-point beauty mesh: 12 normalized UV floats per returned triangle.
 * Each triangle contains source UV x3 followed by destination UV x3. */
int wfd_warp106(const wfd_point_t* landmarks, int num_landmarks,
                const float* params, int num_params, float image_width,
                float image_height, float* out_triangles, int max_triangles);

/* Geometric expression signals: left eye, right eye, mouth opening, brow raise. */
int wfd_expression(const wfd_point_t* landmarks, int num_landmarks,
                   float* out_signals4);

#ifdef __cplusplus
}
#endif

#endif /* WFD_H */
