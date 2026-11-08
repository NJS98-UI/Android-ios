#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <memory>
#include <sys/stat.h>
#include <archive.h>
#include <archive_entry.h>

#include <ApfsLib/Device.h>
#include <ApfsLib/ApfsContainer.h>
#include <ApfsLib/ApfsVolume.h>
#include <ApfsLib/ApfsDir.h>
#include <ApfsLib/DiskStruct.h>
#include <ApfsLib/GptPartitionMap.h>
#include <ApfsLib/Decmpfs.h>
#include <ApfsLib/Util.h>

extern int g_debug;

static ApfsVolume *g_volume = nullptr;

static void write_tar_entry(struct archive *a, const std::string &path,
                            const ApfsDir::Inode &rec,
                            const std::vector<uint8_t> &data,
                            const std::string &link_target)
{
	struct archive_entry *e = archive_entry_new();
	archive_entry_set_pathname(e, path.c_str());
	archive_entry_set_uid(e, rec.owner);
	archive_entry_set_gid(e, rec.group);
	archive_entry_set_mode(e, rec.mode);
	if (rec.optional_present_flags & ApfsDir::Inode::INO_HAS_RDEV)
		archive_entry_set_rdev(e, rec.rdev);
	mode_t m = rec.mode & S_IFMT;
	if (m == S_IFDIR) {
		archive_entry_set_filetype(e, AE_IFDIR);
		archive_entry_set_size(e, 0);
	} else if (m == S_IFLNK) {
		archive_entry_set_filetype(e, AE_IFLNK);
		archive_entry_set_symlink(e, link_target.c_str());
		archive_entry_set_size(e, 0);
	} else if (m == S_IFREG) {
		archive_entry_set_filetype(e, AE_IFREG);
		archive_entry_set_size(e, data.size());
	} else if (m == S_IFCHR || m == S_IFBLK || m == S_IFIFO || m == S_IFSOCK) {
		archive_entry_set_filetype(e, m);
		archive_entry_set_size(e, 0);
	}
	archive_write_header(a, e);
	if (m == S_IFREG && !data.empty())
		archive_write_data(a, data.data(), data.size());
	archive_entry_free(e);
}

static bool read_file_data(ApfsDir &dir, const ApfsDir::Inode &rec,
                           uint64_t ino, std::vector<uint8_t> &out)
{
	if (rec.bsd_flags & APFS_UF_COMPRESSED) {
		std::vector<uint8_t> attr;
		if (!dir.GetAttribute(attr, ino, "com.apple.decmpfs")) {
			fprintf(stderr, "WARN: no decmpfs attr for ino %llu\n", (unsigned long long)ino);
			return false;
		}
		if (!DecompressFile(dir, ino, out, attr)) {
			fprintf(stderr, "WARN: decompress failed for ino %llu\n", (unsigned long long)ino);
			return false;
		}
		return true;
	}
	uint64_t sz = (rec.optional_present_flags & ApfsDir::Inode::INO_HAS_DSTREAM)
	              ? rec.ds_size : 0;
	out.resize(sz);
	if (sz && !dir.ReadFile(out.data(), rec.private_id, 0, sz)) {
		fprintf(stderr, "WARN: read failed for ino %llu size %llu\n",
		        (unsigned long long)ino, (unsigned long long)sz);
		return false;
	}
	return true;
}

static uint64_t g_files = 0, g_dirs = 0, g_decomp = 0, g_errors = 0;

static void walk(struct archive *a, ApfsDir &dir, uint64_t ino,
                 const std::string &prefix)
{
	std::vector<ApfsDir::DirRec> recs;
	if (!dir.ListDirectory(recs, ino))
		return;
	for (const auto &r : recs) {
		if (r.name == "." || r.name == "..")
			continue;
		ApfsDir::Inode rec;
		if (!dir.GetInode(rec, r.file_id))
			continue;
		std::string path = prefix + r.name;
		mode_t m = rec.mode & S_IFMT;
		if (m == S_IFDIR) {
			std::vector<uint8_t> empty;
			write_tar_entry(a, path, rec, empty, "");
			g_dirs++;
			walk(a, dir, r.file_id, path + "/");
		} else if (m == S_IFLNK) {
			std::vector<uint8_t> target;
			std::vector<uint8_t> empty;
			std::string s;
			if (dir.GetAttribute(target, r.file_id, "com.apple.fs.symlink"))
				s.assign(reinterpret_cast<const char *>(target.data()),
				         strnlen(reinterpret_cast<const char *>(target.data()), target.size()));
			write_tar_entry(a, path, rec, empty, s);
			g_files++;
		} else if (m == S_IFREG) {
			std::vector<uint8_t> data;
			if (!read_file_data(dir, rec, r.file_id, data)) {
				g_errors++;
				continue;
			}
			if (rec.bsd_flags & APFS_UF_COMPRESSED)
				g_decomp++;
			write_tar_entry(a, path, rec, data, "");
			g_files++;
		} else {
			std::vector<uint8_t> empty;
			write_tar_entry(a, path, rec, empty, "");
			g_files++;
		}
	}
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: %s DMG OUT.tar [--volume N] [--prefix P]\n", argv[0]);
		return 2;
	}
	const char *dmg = argv[1], *out = argv[2];
	int volidx = 0;
	std::string prefix = "";
	for (int i = 3; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--volume")) volidx = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--prefix")) prefix = argv[i + 1];
	}

	std::unique_ptr<Device> device(Device::OpenDevice(dmg));
	if (!device) { fprintf(stderr, "cannot open %s\n", dmg); return 1; }
	uint64_t offset = 0, size = device->GetSize();
	GptPartitionMap gpt;
	if (gpt.LoadAndVerify(*device)) {
		int p = gpt.FindFirstAPFSPartition();
		if (p >= 0) gpt.GetPartitionOffsetAndSize(p, offset, size);
	}
	ApfsContainer container(device.get(), offset, size);
	if (!container.Init()) { fprintf(stderr, "container init failed\n"); return 1; }
	g_volume = container.GetVolume(volidx);
	if (!g_volume) { fprintf(stderr, "cannot get volume %d\n", volidx); return 1; }
	fprintf(stderr, "volume: %s\n", g_volume->name());

	struct archive *a = archive_write_new();
	archive_write_set_format_pax_restricted(a);
	archive_write_open_filename(a, out);

	ApfsDir dir(*g_volume);
	if (!prefix.empty())
		walk(a, dir, ROOT_DIR_INO_NUM, prefix);
	else
		walk(a, dir, ROOT_DIR_INO_NUM, "");

	archive_write_close(a);
	archive_write_free(a);
	fprintf(stderr, "done: %llu dirs, %llu files, %llu decompressed, %llu errors\n",
	        (unsigned long long)g_dirs, (unsigned long long)g_files,
	        (unsigned long long)g_decomp, (unsigned long long)g_errors);
	return g_errors ? 3 : 0;
}
