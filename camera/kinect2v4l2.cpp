#include <libfreenect2/libfreenect2.hpp>
#include <libfreenect2/frame_listener_impl.h>
#include <libfreenect2/registration.h>
#include <libfreenect2/packet_pipeline.h>
#include <iostream>
#include <signal.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <cstring>
#include <algorithm>

bool stop = false;
void sighandler(int) { stop = true; }

// Simple BGRX to YUV420 conversion
void convertBGRXtoYUV420(const uint8_t* bgrx, uint8_t* yuv, int width, int height) {
    uint8_t* y = yuv;
    uint8_t* u = yuv + (width * height);
    uint8_t* v = u + (width * height / 4);
    
    for (int j = 0; j < height; j++) {
        for (int i = 0; i < width; i++) {
            int idx = (j * width + i) * 4;
            uint8_t b = bgrx[idx];
            uint8_t g = bgrx[idx + 1];
            uint8_t r = bgrx[idx + 2];
            
            // Y plane
            y[j * width + i] = std::min(255, std::max(0, (int)(0.299 * r + 0.587 * g + 0.114 * b)));
            
            // U and V planes (subsample 2x2)
            if (j % 2 == 0 && i % 2 == 0) {
                int uv_idx = (j / 2) * (width / 2) + (i / 2);
                u[uv_idx] = std::min(255, std::max(0, (int)(-0.147 * r - 0.289 * g + 0.436 * b + 128)));
                v[uv_idx] = std::min(255, std::max(0, (int)(0.615 * r - 0.515 * g - 0.100 * b + 128)));
            }
        }
    }
}

int main(int argc, char *argv[]) {
    std::string device_path = "/dev/video2";
    if (argc > 1) device_path = argv[1];

    // Open V4L2 device
    int fd = open(device_path.c_str(), O_RDWR);
    if (fd < 0) {
        std::cerr << "Failed to open " << device_path << std::endl;
        return 1;
    }

    // Set format
    struct v4l2_format fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT;
    fmt.fmt.pix.width = 1920;
    fmt.fmt.pix.height = 1080;
    fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUV420;
    fmt.fmt.pix.sizeimage = 1920 * 1080 * 3 / 2;
    fmt.fmt.pix.field = V4L2_FIELD_NONE;

    if (ioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        std::cerr << "Failed to set format" << std::endl;
        close(fd);
        return 1;
    }

    // Initialize Kinect
    libfreenect2::Freenect2 freenect2;
    libfreenect2::Freenect2Device *dev = nullptr;
    libfreenect2::PacketPipeline *pipeline = nullptr;

    if (freenect2.enumerateDevices() == 0) {
        std::cerr << "No Kinect device found!" << std::endl;
        close(fd);
        return 1;
    }

    std::string serial = freenect2.getDefaultDeviceSerialNumber();
    
    // Try different pipelines for better performance
    pipeline = new libfreenect2::CpuPacketPipeline();
    
    dev = freenect2.openDevice(serial, pipeline);
    if (!dev) {
        std::cerr << "Failed to open Kinect device!" << std::endl;
        close(fd);
        return 1;
    }

    // Setup listener for color only
    libfreenect2::SyncMultiFrameListener listener(libfreenect2::Frame::Color);
    libfreenect2::FrameMap frames;
    dev->setColorFrameListener(&listener);

    // Start device
    if (!dev->startStreams(true, false)) {  // RGB only, no depth
        std::cerr << "Failed to start streams!" << std::endl;
        dev->close();
        close(fd);
        return 1;
    }

    std::cout << "Kinect started, streaming to " << device_path << std::endl;
    std::cout << "No window needed - direct streaming!" << std::endl;
    std::cout << "Press Ctrl+C to stop" << std::endl;

    signal(SIGINT, sighandler);

    // Allocate YUV buffer
    size_t yuv_size = 1920 * 1080 * 3 / 2;
    uint8_t *yuv_buffer = new uint8_t[yuv_size];

    while (!stop) {
        if (!listener.waitForNewFrame(frames, 10 * 1000)) {
            std::cerr << "Timeout waiting for frames" << std::endl;
            continue;
        }

        libfreenect2::Frame *rgb = frames[libfreenect2::Frame::Color];
        
        // Convert BGRX to YUV420
        convertBGRXtoYUV420((uint8_t*)rgb->data, yuv_buffer, 1920, 1080);
        
        // Write to V4L2 device
        if (write(fd, yuv_buffer, yuv_size) < 0) {
            std::cerr << "Failed to write to device" << std::endl;
        }
        
        listener.release(frames);
    }

    delete[] yuv_buffer;
    dev->stop();
    dev->close();
    close(fd);

    return 0;
}