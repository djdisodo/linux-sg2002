// SPDX-License-Identifier: GPL-2.0
/*
 * Wave4 userspace benchmark:
 * - Uses OUTPUT MMAP buffers and re-queues dequeued OUTPUT indices.
 * - Uses CAPTURE MMAP buffers to collect encoded HEVC bitstream.
 *
 * This avoids dma-heap dependencies while still isolating low-overhead
 * repeated-buffer behavior in the V4L2 encode path.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/videodev2.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

struct options {
	const char *device;
	const char *output_path;
	uint32_t width;
	uint32_t height;
	uint32_t fps;
	uint32_t frames;
	uint32_t bitrate;
	uint32_t cap_sizeimage;
	uint32_t cap_buffers;
	uint32_t out_buffers;
	bool verbose;
};

struct mmap_buf {
	void *addr;
	size_t length;
};

static void usage(const char *prog)
{
	fprintf(stderr,
		"Usage: %s [options]\n"
		"\n"
		"Options:\n"
		"  -d, --device <path>       V4L2 M2M encoder node (default: /dev/video0)\n"
		"  -o, --output <path>       Encoded output bitstream (default: /tmp/w4_mmap_reuse.hevc)\n"
		"  -w, --width <px>          Width (default: 1920)\n"
		"  -h, --height <px>         Height (default: 1088)\n"
		"  -r, --fps <n>             Source fps metadata (default: 30)\n"
		"  -n, --frames <n>          Number of repeated input frames (default: 300)\n"
		"  -b, --bitrate <bps>       Target bitrate via V4L2_CID_MPEG_VIDEO_BITRATE (default: 1000000)\n"
		"  -s, --sizeimage <bytes>   CAPTURE sizeimage (default: 1048576)\n"
		"  -c, --cap-bufs <n>        CAPTURE mmap buffer count (default: 4)\n"
		"  -q, --out-bufs <n>        OUTPUT mmap buffer count (default: 2)\n"
		"  -v, --verbose             Verbose log\n"
		"      --help                Show this help\n",
		prog);
}

static int xioctl(int fd, unsigned long req, void *arg)
{
	int ret;

	do {
		ret = ioctl(fd, req, arg);
	} while (ret < 0 && errno == EINTR);

	return ret;
}

static int64_t mono_ns(void)
{
	struct timespec ts;

	if (clock_gettime(CLOCK_MONOTONIC, &ts) < 0)
		return -1;

	return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static double tv_to_sec(const struct timeval *tv)
{
	return (double)tv->tv_sec + (double)tv->tv_usec / 1000000.0;
}

static int set_ctrl_best_effort(int fd, uint32_t id, int32_t value, bool verbose)
{
	struct v4l2_control ctrl;

	memset(&ctrl, 0, sizeof(ctrl));
	ctrl.id = id;
	ctrl.value = value;

	if (xioctl(fd, VIDIOC_S_CTRL, &ctrl) == 0)
		return 0;

	if (verbose) {
		fprintf(stderr, "warn: VIDIOC_S_CTRL id=0x%x failed: %s\n",
			id, strerror(errno));
	}
	return -1;
}

static int set_output_format(int fd, uint32_t width, uint32_t height,
			     uint32_t *sizeimage, uint32_t *bytesperline)
{
	struct v4l2_format fmt;

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	fmt.fmt.pix_mp.width = width;
	fmt.fmt.pix_mp.height = height;
	fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_NV12;
	fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
	fmt.fmt.pix_mp.num_planes = 1;
	fmt.fmt.pix_mp.plane_fmt[0].sizeimage = width * height * 3 / 2;
	fmt.fmt.pix_mp.plane_fmt[0].bytesperline = width;

	if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
		perror("VIDIOC_S_FMT OUTPUT");
		return -1;
	}

	*sizeimage = fmt.fmt.pix_mp.plane_fmt[0].sizeimage;
	*bytesperline = fmt.fmt.pix_mp.plane_fmt[0].bytesperline;
	if (!*bytesperline)
		*bytesperline = width;

	return 0;
}

static int set_capture_format(int fd, uint32_t width, uint32_t height,
			      uint32_t req_sizeimage, uint32_t *sizeimage)
{
	struct v4l2_format fmt;

	memset(&fmt, 0, sizeof(fmt));
	fmt.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	fmt.fmt.pix_mp.width = width;
	fmt.fmt.pix_mp.height = height;
	fmt.fmt.pix_mp.pixelformat = V4L2_PIX_FMT_HEVC;
	fmt.fmt.pix_mp.field = V4L2_FIELD_NONE;
	fmt.fmt.pix_mp.num_planes = 1;
	fmt.fmt.pix_mp.plane_fmt[0].sizeimage = req_sizeimage;

	if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
		perror("VIDIOC_S_FMT CAPTURE");
		return -1;
	}

	*sizeimage = fmt.fmt.pix_mp.plane_fmt[0].sizeimage;
	return 0;
}

static int reqbufs(int fd, enum v4l2_buf_type type, enum v4l2_memory memory, uint32_t count,
		   uint32_t *actual_count)
{
	struct v4l2_requestbuffers req;

	memset(&req, 0, sizeof(req));
	req.type = type;
	req.memory = memory;
	req.count = count;

	if (xioctl(fd, VIDIOC_REQBUFS, &req) < 0) {
		perror("VIDIOC_REQBUFS");
		return -1;
	}

	*actual_count = req.count;
	return 0;
}

static int qbuf_capture_mmap(int fd, uint32_t index)
{
	struct v4l2_buffer buf;
	struct v4l2_plane planes[VIDEO_MAX_PLANES];

	memset(&buf, 0, sizeof(buf));
	memset(planes, 0, sizeof(planes));

	buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
	buf.memory = V4L2_MEMORY_MMAP;
	buf.index = index;
	buf.length = 1;
	buf.m.planes = planes;
	buf.field = V4L2_FIELD_NONE;

	if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
		perror("VIDIOC_QBUF CAPTURE");
		return -1;
	}

	return 0;
}

static int qbuf_output_mmap(int fd, uint32_t index, uint32_t bytesused, uint32_t length)
{
	struct v4l2_buffer buf;
	struct v4l2_plane planes[VIDEO_MAX_PLANES];

	memset(&buf, 0, sizeof(buf));
	memset(planes, 0, sizeof(planes));

	buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
	buf.memory = V4L2_MEMORY_MMAP;
	buf.index = index;
	buf.length = 1;
	buf.m.planes = planes;
	buf.field = V4L2_FIELD_NONE;
	planes[0].bytesused = bytesused;
	planes[0].length = length;

	if (xioctl(fd, VIDIOC_QBUF, &buf) < 0) {
		perror("VIDIOC_QBUF OUTPUT");
		return -1;
	}

	return 0;
}

static void fill_nv12_pattern(uint8_t *buf, size_t size, uint32_t width, uint32_t height,
			      uint32_t stride)
{
	uint32_t x, y;
	size_t y_size;
	uint8_t *uv;

	if (!stride)
		stride = width;

	y_size = (size_t)stride * height;
	if (y_size > size)
		y_size = size;

	for (y = 0; y < height; y++) {
		size_t row_off = (size_t)y * stride;
		uint8_t *row = buf + row_off;

		if (row_off >= y_size)
			break;

		for (x = 0; x < stride; x++) {
			if (row_off + x >= y_size)
				break;
			/* Static pattern reused for all queued frames. */
			row[x] = (uint8_t)((x + y) & 0xff);
		}
	}

	uv = buf + y_size;
	memset(uv, 0x80, size - y_size);
}

static int write_all(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;

	while (len > 0) {
		ssize_t ret = write(fd, p, len);
		if (ret < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (ret == 0)
			return -1;
		p += ret;
		len -= (size_t)ret;
	}

	return 0;
}

int main(int argc, char **argv)
{
	const struct option long_opts[] = {
		{ "device", required_argument, NULL, 'd' },
		{ "output", required_argument, NULL, 'o' },
		{ "width", required_argument, NULL, 'w' },
		{ "height", required_argument, NULL, 'h' },
		{ "fps", required_argument, NULL, 'r' },
		{ "frames", required_argument, NULL, 'n' },
		{ "bitrate", required_argument, NULL, 'b' },
		{ "sizeimage", required_argument, NULL, 's' },
		{ "cap-bufs", required_argument, NULL, 'c' },
		{ "out-bufs", required_argument, NULL, 'q' },
		{ "verbose", no_argument, NULL, 'v' },
		{ "help", no_argument, NULL, 1 },
		{ 0, 0, 0, 0 },
	};
	struct options opt = {
		.device = "/dev/video0",
		.output_path = "/tmp/w4_mmap_reuse.hevc",
		.width = 1920,
		.height = 1088,
		.fps = 30,
		.frames = 300,
		.bitrate = 1000000,
		.cap_sizeimage = 1024 * 1024,
		.cap_buffers = 4,
		.out_buffers = 2,
		.verbose = false,
	};
	struct mmap_buf *cap = NULL;
	struct mmap_buf *out = NULL;
	struct rusage ru_start, ru_end;
	struct v4l2_capability vcaps;
	uint32_t out_sizeimage = 0, out_bytesperline = 0;
	uint32_t cap_sizeimage = 0, cap_count = 0, out_count = 0;
	uint32_t frame_bytes;
	uint32_t initial_out_q = 0;
	int vfd = -1, out_fd = -1;
	int streamon_cap = 0, streamon_out = 0;
	uint32_t out_submitted = 0, cap_done = 0;
	int out_pending = 0;
	bool eos_queued = false, eos_seen = false;
	int64_t t0, t1;
	double elapsed_s, fps, user_s, sys_s;
	int idle_loops = 0;
	int c;
	int ret = EXIT_FAILURE;

	while ((c = getopt_long(argc, argv, "d:o:w:h:r:n:b:s:c:q:v", long_opts, NULL)) != -1) {
		switch (c) {
		case 'd':
			opt.device = optarg;
			break;
		case 'o':
			opt.output_path = optarg;
			break;
		case 'w':
			opt.width = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'h':
			opt.height = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'r':
			opt.fps = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'n':
			opt.frames = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'b':
			opt.bitrate = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 's':
			opt.cap_sizeimage = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'c':
			opt.cap_buffers = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'q':
			opt.out_buffers = (uint32_t)strtoul(optarg, NULL, 0);
			break;
		case 'v':
			opt.verbose = true;
			break;
		case 1:
			usage(argv[0]);
			return EXIT_SUCCESS;
		default:
			usage(argv[0]);
			return EXIT_FAILURE;
		}
	}

	if (!opt.width || !opt.height || !opt.frames || !opt.fps ||
	    opt.cap_buffers < 2 || opt.out_buffers < 1) {
		fprintf(stderr, "invalid numeric option values\n");
		return EXIT_FAILURE;
	}

	vfd = open(opt.device, O_RDWR | O_NONBLOCK | O_CLOEXEC);
	if (vfd < 0) {
		perror("open video device");
		goto cleanup;
	}

	memset(&vcaps, 0, sizeof(vcaps));
	if (xioctl(vfd, VIDIOC_QUERYCAP, &vcaps) < 0) {
		perror("VIDIOC_QUERYCAP");
		goto cleanup;
	}

	if (!(vcaps.capabilities & V4L2_CAP_VIDEO_M2M_MPLANE)) {
		fprintf(stderr, "%s does not expose V4L2_CAP_VIDEO_M2M_MPLANE\n", opt.device);
		goto cleanup;
	}

	printf("device: %s (driver=%s card=%s bus=%s)\n",
	       opt.device, vcaps.driver, vcaps.card, vcaps.bus_info);

	if (set_output_format(vfd, opt.width, opt.height, &out_sizeimage, &out_bytesperline) < 0)
		goto cleanup;
	if (set_capture_format(vfd, opt.width, opt.height, opt.cap_sizeimage, &cap_sizeimage) < 0)
		goto cleanup;

	(void)set_ctrl_best_effort(vfd, V4L2_CID_MPEG_VIDEO_BITRATE, (int32_t)opt.bitrate,
				   opt.verbose);

	{
		struct v4l2_streamparm parm;

		memset(&parm, 0, sizeof(parm));
		parm.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		parm.parm.output.timeperframe.numerator = 1;
		parm.parm.output.timeperframe.denominator = opt.fps;
		(void)xioctl(vfd, VIDIOC_S_PARM, &parm);
	}

	if (reqbufs(vfd, V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE, V4L2_MEMORY_MMAP, opt.cap_buffers,
		    &cap_count) < 0)
		goto cleanup;
	if (cap_count < 2) {
		fprintf(stderr, "insufficient capture buffers: %u\n", cap_count);
		goto cleanup;
	}

	if (reqbufs(vfd, V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE, V4L2_MEMORY_MMAP, opt.out_buffers,
		    &out_count) < 0)
		goto cleanup;
	if (out_count < 1) {
		fprintf(stderr, "insufficient output buffers: %u\n", out_count);
		goto cleanup;
	}

	cap = calloc(cap_count, sizeof(*cap));
	if (!cap) {
		perror("calloc capture buffers");
		goto cleanup;
	}
	out = calloc(out_count, sizeof(*out));
	if (!out) {
		perror("calloc output buffers");
		goto cleanup;
	}

	for (uint32_t i = 0; i < cap_count; i++) {
		struct v4l2_buffer buf;
		struct v4l2_plane planes[VIDEO_MAX_PLANES];

		memset(&buf, 0, sizeof(buf));
		memset(planes, 0, sizeof(planes));
		buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		buf.length = 1;
		buf.m.planes = planes;

		if (xioctl(vfd, VIDIOC_QUERYBUF, &buf) < 0) {
			perror("VIDIOC_QUERYBUF CAPTURE");
			goto cleanup;
		}

		cap[i].length = planes[0].length;
		cap[i].addr = mmap(NULL, cap[i].length, PROT_READ | PROT_WRITE, MAP_SHARED, vfd,
				   planes[0].m.mem_offset);
		if (cap[i].addr == MAP_FAILED) {
			perror("mmap capture");
			goto cleanup;
		}

		if (qbuf_capture_mmap(vfd, i) < 0)
			goto cleanup;
	}

	for (uint32_t i = 0; i < out_count; i++) {
		struct v4l2_buffer buf;
		struct v4l2_plane planes[VIDEO_MAX_PLANES];

		memset(&buf, 0, sizeof(buf));
		memset(planes, 0, sizeof(planes));
		buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		buf.memory = V4L2_MEMORY_MMAP;
		buf.index = i;
		buf.length = 1;
		buf.m.planes = planes;

		if (xioctl(vfd, VIDIOC_QUERYBUF, &buf) < 0) {
			perror("VIDIOC_QUERYBUF OUTPUT");
			goto cleanup;
		}

		out[i].length = planes[0].length;
		out[i].addr = mmap(NULL, out[i].length, PROT_READ | PROT_WRITE, MAP_SHARED, vfd,
				   planes[0].m.mem_offset);
		if (out[i].addr == MAP_FAILED) {
			perror("mmap output");
			goto cleanup;
		}
	}

	for (uint32_t i = 0; i < out_count; i++) {
		fill_nv12_pattern(out[i].addr, out[i].length,
				  opt.width, opt.height, out_bytesperline);
	}

	out_fd = open(opt.output_path, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0644);
	if (out_fd < 0) {
		perror("open output file");
		goto cleanup;
	}

	frame_bytes = opt.width * opt.height * 3 / 2;
	if (frame_bytes > out[0].length)
		frame_bytes = out[0].length;

	initial_out_q = opt.frames < out_count ? opt.frames : out_count;
	for (uint32_t i = 0; i < initial_out_q; i++) {
		if (qbuf_output_mmap(vfd, i, frame_bytes, out[i].length) < 0)
			goto cleanup;
	}
	out_submitted = initial_out_q;
	out_pending = (int)initial_out_q;

	{
		enum v4l2_buf_type type;

		type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		if (xioctl(vfd, VIDIOC_STREAMON, &type) < 0) {
			perror("VIDIOC_STREAMON CAPTURE");
			goto cleanup;
		}
		streamon_cap = 1;

		type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		if (xioctl(vfd, VIDIOC_STREAMON, &type) < 0) {
			perror("VIDIOC_STREAMON OUTPUT");
			goto cleanup;
		}
		streamon_out = 1;
	}

	getrusage(RUSAGE_SELF, &ru_start);
	t0 = mono_ns();

	while (!eos_seen) {
		bool progress = false;

		for (;;) {
			struct v4l2_buffer buf;
			struct v4l2_plane planes[VIDEO_MAX_PLANES];

			memset(&buf, 0, sizeof(buf));
			memset(planes, 0, sizeof(planes));
			buf.type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
			buf.memory = V4L2_MEMORY_MMAP;
			buf.length = 1;
			buf.m.planes = planes;

			if (xioctl(vfd, VIDIOC_DQBUF, &buf) < 0) {
				if (errno == EAGAIN)
					break;
				perror("VIDIOC_DQBUF OUTPUT");
				goto cleanup;
			}

			progress = true;
			if (out_pending > 0)
				out_pending--;

			if (!eos_queued) {
				if (out_submitted < opt.frames) {
					if (qbuf_output_mmap(vfd, buf.index, frame_bytes,
							     out[buf.index].length) < 0) {
						goto cleanup;
					}
					out_submitted++;
					out_pending++;
				} else {
					if (qbuf_output_mmap(vfd, buf.index, 0,
							     out[buf.index].length) < 0) {
						goto cleanup;
					}
					eos_queued = true;
					out_pending++;
				}
			}
		}

		for (;;) {
			struct v4l2_buffer buf;
			struct v4l2_plane planes[VIDEO_MAX_PLANES];
			uint32_t idx;

			memset(&buf, 0, sizeof(buf));
			memset(planes, 0, sizeof(planes));
			buf.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
			buf.memory = V4L2_MEMORY_MMAP;
			buf.length = 1;
			buf.m.planes = planes;

			if (xioctl(vfd, VIDIOC_DQBUF, &buf) < 0) {
				if (errno == EAGAIN)
					break;
				perror("VIDIOC_DQBUF CAPTURE");
				goto cleanup;
			}

			progress = true;
			idx = buf.index;
			if (idx >= cap_count) {
				fprintf(stderr, "invalid capture index %u\n", idx);
				goto cleanup;
			}

			if (planes[0].bytesused > 0) {
				if (write_all(out_fd, cap[idx].addr, planes[0].bytesused) < 0) {
					perror("write output");
					goto cleanup;
				}
				cap_done++;
			}

			if ((buf.flags & V4L2_BUF_FLAG_LAST) ||
			    (eos_queued && planes[0].bytesused == 0)) {
				eos_seen = true;
				break;
			}

			if (qbuf_capture_mmap(vfd, idx) < 0)
				goto cleanup;
		}

		if (progress) {
			idle_loops = 0;
		} else if (eos_queued && out_pending == 0) {
			eos_seen = true;
		} else {
			struct timespec ts;

			idle_loops++;
			if (idle_loops > 20000) {
				fprintf(stderr, "timeout waiting for V4L2 events\n");
				goto cleanup;
			}

			ts.tv_sec = 0;
			ts.tv_nsec = 5 * 1000 * 1000; /* 5 ms */
			nanosleep(&ts, NULL);
		}
	}

	t1 = mono_ns();
	getrusage(RUSAGE_SELF, &ru_end);

	elapsed_s = (double)(t1 - t0) / 1000000000.0;
	if (elapsed_s <= 0.0)
		elapsed_s = 0.000001;
	fps = (double)cap_done / elapsed_s;
	user_s = tv_to_sec(&ru_end.ru_utime) - tv_to_sec(&ru_start.ru_utime);
	sys_s = tv_to_sec(&ru_end.ru_stime) - tv_to_sec(&ru_start.ru_stime);

	printf("output_mode: mmap_requeue\n");
	printf("output_buffers: %u\n", out_count);
	printf("submitted_frames: %u\n",
	       out_submitted > 0 ? out_submitted - (eos_queued ? 1 : 0) : 0);
	printf("encoded_frames: %u\n", cap_done);
	printf("elapsed_sec: %.3f\n", elapsed_s);
	printf("throughput_fps: %.3f\n", fps);
	printf("cpu_user_sec: %.3f\n", user_s);
	printf("cpu_sys_sec: %.3f\n", sys_s);
	printf("output_file: %s\n", opt.output_path);

	ret = EXIT_SUCCESS;

cleanup:
	if (streamon_out) {
		enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
		(void)xioctl(vfd, VIDIOC_STREAMOFF, &type);
	}
	if (streamon_cap) {
		enum v4l2_buf_type type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
		(void)xioctl(vfd, VIDIOC_STREAMOFF, &type);
	}
	if (out) {
		for (uint32_t i = 0; i < out_count; i++) {
			if (out[i].addr && out[i].addr != MAP_FAILED)
				munmap(out[i].addr, out[i].length);
		}
		free(out);
	}
	if (cap) {
		for (uint32_t i = 0; i < cap_count; i++) {
			if (cap[i].addr && cap[i].addr != MAP_FAILED)
				munmap(cap[i].addr, cap[i].length);
		}
		free(cap);
	}
	if (out_fd >= 0)
		close(out_fd);
	if (vfd >= 0)
		close(vfd);

	return ret;
}
