/++
Prerequisites:
-------------------------
A working dmd installation to compile this script (also requires libcurl).
Install Vagrant (https://learnchef.opscode.com/screencasts/install-vagrant/)
Install VirtualBox (https://learnchef.opscode.com/screencasts/install-virtual-box/)
+/
import std.conv, std.exception, std.file, std.path, std.process, std.stdio, std.string;
import common;

version (Posix) {} else { static assert(0, "This must be run on a Posix machine."); }

// Open Source OS boxes are from http://www.vagrantbox.es/
// Note: The pull request to add the FreeBSD-8.4 boxes to vagrantbox.es is still pending, https://github.com/garethr/vagrantboxes-heroku/pull/246.

/// Name: create_dmd_release-freebsd-64
/// VagrantBox.es: FreeBSD 8.4 i386 (minimal, No Guest Additions, UFS)
enum freebsd_32 = Box(OS.freebsd, Model._32, "http://dlang.dawg.eu/vagrant/FreeBSD-8.4-i386.box",
                      "sudo pkg_add -r curl git gmake;");

// Note: pull request for vagrantbox.es pending
/// Name: create_dmd_release-freebsd-64
/// VagrantBox.es: FreeBSD 8.4 amd64 (minimal, No Guest Additions, UFS)
enum freebsd_64 = Box(OS.freebsd, Model._64, "http://dlang.dawg.eu/vagrant/FreeBSD-8.4-amd64.box",
                      "sudo pkg_add -r curl git gmake;");

/// Name: create_dmd_release-linux
/// VagrantBox.es: Puppetlabs Debian 6.0.7 x86_64, VBox 4.2.10, No Puppet or Chef
enum linux_both = Box(OS.linux, Model._both, "http://puppet-vagrant-boxes.puppetlabs.com/debian-607-x64-vbox4210-nocm.box",
                    "sudo apt-get -y update; sudo apt-get -y install git g++-multilib;");

/// OSes that require licenses must be setup manually

/// Name: create_dmd_release-osx
/// Setup: Preparing OSX-10.8 box, https://gist.github.com/MartinNowak/8156507
enum osx_both = Box(OS.osx, Model._both, null,
                  null);

/// Name: create_dmd_release-windows
/// Setup: Preparing Win7x64 box, https://gist.github.com/MartinNowak/8270666
enum windows_both = Box(OS.windows, Model._both, null,
                  null);

enum boxes = [windows_both, osx_both, freebsd_32, freebsd_64, linux_both];


enum OS { freebsd, linux, osx, windows, }
enum Model { _both = 0, _32 = 32, _64 = 64 }

struct Box
{
    void up()
    {
        _tmpdir = mkdtemp();
        std.file.write(buildPath(_tmpdir, "Vagrantfile"), vagrantFile);

        // bring up the virtual box (downloads missing images)
        run("cd "~_tmpdir~" && vagrant up");

        _isUp = true;

        // save the ssh config file
        run("cd "~_tmpdir~" && vagrant ssh-config > ssh.cfg");

        provision();
    }

    void destroy()
    {
        try
        {
            if (_isUp) run("cd "~_tmpdir~" && vagrant destroy -f");
            if (_tmpdir.length) rmdirRecurse(_tmpdir);
        }
        finally
        {
            _isUp = false;
            _tmpdir = null;
        }
    }

    void halt()
    {
        try
            if (_isUp) run("cd "~_tmpdir~" && vagrant halt -f");
        finally
            _isUp = false;
    }

    ProcessPipes shell(Redirect redirect = Redirect.stdin)
    in { assert(redirect & Redirect.stdin); }
    body
    {
        ProcessPipes sh;
        if (_os == OS.windows)
        {
            sh = pipeProcess(["ssh", "-F", sshcfg, "default", "powershell", "-Command", "-"], redirect);
        }
        else
        {
            sh = pipeProcess(["ssh", "-F", sshcfg, "default", "bash"], redirect);
            // enable verbose echo and stop on error
            sh.exec("set -e -v");
        }
        return sh;
    }

    void scp(string src, string tgt)
    {
        run("scp -rq -F "~sshcfg~" "~src~" "~tgt);
    }

private:
    @property string vagrantFile()
    {
        auto res =
            `
            VAGRANTFILE_API_VERSION = "2"

            Vagrant.configure(VAGRANTFILE_API_VERSION) do |config|
                config.vm.box = "create_dmd_release-`~platform~`"
                config.vm.box_url = "`~_url~`"
                # disable shared folders, because the guest additions are missing
                config.vm.synced_folder ".", "/vagrant", :disabled => true

                config.vm.provider :virtualbox do |vb|
                  vb.customize ["modifyvm", :id, "--memory", "4096"]
                  vb.customize ["modifyvm", :id, "--cpus", "4"]
                  vb.customize ["modifyvm", :id, "--accelerate3d", "off"]
                  vb.customize ["modifyvm", :id, "--audio", "none"]
                  vb.customize ["modifyvm", :id, "--usb", "off"]
                end
            `;
        if (_os == OS.windows)
            res ~=
            `
                config.vm.guest = :windows
                # Port forward WinRM and RDP
                config.vm.network :forwarded_port, guest: 3389, host: 3389
                config.vm.network :forwarded_port, guest: 5985, host: 5985, id: "winrm", auto_correct: true
            `;
        res ~=
            `
            end
            `;
        return res.outdent();
    }

    void provision()
    {
        auto sh = shell();
        // install prerequisites
        sh.exec(_setup);
        // wait for completion
        sh.close();
    }

    @property string platform() { return _model == Model._both ? osS : osS ~ "-" ~ modelS; }
    @property string osS() { return to!string(_os); }
    @property string modelS() { return _model == Model._both ? "" : to!string(cast(uint)_model); }
    @property string sshcfg() { return buildPath(_tmpdir, "ssh.cfg"); }

    OS _os;
    Model _model;
    string _url; /// optional url of the image
    string _setup; /// initial provisioning script
    string _tmpdir;
    bool _isUp;
}

void run(string cmd) { writeln("\033[36m", cmd, "\033[0m"); enforce(wait(spawnShell(cmd)) == 0); }

void exec(ProcessPipes pipes, string cmd)
{
    writeln("\033[33m", cmd, "\033[0m");
    pipes.stdin.writeln(cmd);
}

void close(ProcessPipes pipes)
{
    pipes.stdin.close();
    // TODO: capture stderr and attach it to enforce
    enforce(wait(pipes.pid) == 0);
}

//------------------------------------------------------------------------------
// Copy additional release binaries from the previous release

void copyExtraBinaries(string workDir, Box box)
{
    import std.range;

    static auto addPrefix(R)(string prefix, R rng)
    {
        return rng.map!(a => prefix ~ a)();
    }

    string[] files;
    final switch (box._os)
    {
    case OS.windows:
        enum binFiles = [
            "windbg.hlp", "ddemangle.exe", "lib.exe", "link.exe", "make.exe",
            "replace.exe", "shell.exe", "windbg.exe", "dm.dll", "eecxxx86.dll",
            "emx86.dll", "mspdb41.dll", "shcv.dll", "tlloc.dll",
        ];
        enum libFiles = [
            "advapi32.lib", "COMCTL32.LIB", "comdlg32.lib", "CTL3D32.LIB",
            "gdi32.lib", "kernel32.lib", "ODBC32.LIB", "ole32.lib", "OLEAUT32.LIB",
            "rpcrt4.lib", "shell32.lib", "snn.lib", "user32.lib", "uuid.lib",
            "winmm.lib", "winspool.lib", "WS2_32.LIB", "wsock32.lib",
        ];
        files = addPrefix("dmd2/windows/", chain(addPrefix("bin/", binFiles), addPrefix("lib/", libFiles)))
            .array();
        break;

    case OS.linux:
        files = addPrefix("dmd2/linux/", ["bin32/dumpobj", "bin64/dumpobj", "bin32/obj2asm", "bin64/obj2asm"])
            .array();
        break;

    case OS.freebsd:
        // no 64-bit binaries for FreeBSD :(
        files = addPrefix("dmd2/freebsd/", ["bin32/dumpobj", "bin32/obj2asm", "bin32/shell"])
            .array();
        break;

    case OS.osx:
        files = addPrefix("dmd2/osx/", ["bin/dumpobj", "bin/obj2asm", "bin/shell"])
            .array();
        break;
    }
    copyFiles(files, workDir~"/old-dmd", workDir~"/extraBins");
    box.scp(workDir~"/extraBins", "default:");
}

//------------------------------------------------------------------------------
// builds a dmd.VERSION.OS.MODEL.zip on the vanilla VirtualBox image

void runBuild(Box box, string gitTag, bool combine)
{
    auto sh = box.shell();

    string rdmd;
    final switch (box._os)
    {
    case OS.freebsd:
        rdmd = "old-dmd/dmd2/freebsd/bin"~box.modelS~"/rdmd"~
            " --compiler=old-dmd/dmd2/freebsd/bin"~box.modelS~"/dmd";
        break;
    case OS.linux:
        rdmd = "old-dmd/dmd2/linux/bin64/rdmd"~
            " --compiler=old-dmd/dmd2/linux/bin64/dmd";
        break;
    case OS.windows:
        sh.stdin.writeln(`copy old-dmd\dmd2\windows\bin\libcurl.dll .`);
        sh.stdin.writeln(`copy old-dmd\dmd2\windows\bin\libcurl.dll clones\dlang.org`);
        sh.stdin.writeln(`copy old-dmd\dmd2\windows\lib\curl.lib clones\dlang.org`);
        rdmd = `old-dmd\dmd2\windows\bin\rdmd.exe`~
            ` --compiler=old-dmd\dmd2\windows\bin\dmd.exe`;
        break;
    case OS.osx:
        rdmd = "old-dmd/dmd2/osx/bin/rdmd"
            " --compiler=old-dmd/dmd2/osx/bin/dmd";
        break;
    }

    auto cmd = rdmd~" create_dmd_release --extras=extraBins --archive --use-clone=clones";
    if (box._model != Model._both)
        cmd ~= " --only-" ~ box.modelS;
    cmd ~= " " ~ gitTag;

    sh.exec(cmd);
    if (combine)
        sh.exec(rdmd~" create_dmd_release --extras=extraBins --combine --use-clone=clones "~gitTag);

    sh.close();
    // copy out created zip files
    box.scp("default:dmd."~gitTag~"."~box.platform~".zip", ".");
    if (combine)
        box.scp("default:dmd."~gitTag~".zip", ".");

    // Build package installers
    immutable ver = gitTag.chompPrefix("v");

    final switch (box._os)
    {
    case OS.freebsd:
        break;

    case OS.linux:
        // TBD
        break;

    case OS.windows:
    {
        sh = box.shell();
        sh.stdin.writeln(`cd clones\installer\windows`);
        sh.stdin.writeln(`&'C:\Program Files (x86)\NSIS\makensis' /DVersion2=`~ver~` dinstaller.nsi`);
        sh.stdin.writeln(`copy dmd-`~ver~`.exe C:\Users\vagrant\dmd-`~ver~`.exe`);
        sh.close();
        box.scp("default:dmd-"~ver~".exe", ".");
    }
    break;

    case OS.osx:
        // TBD
        break;
    }
}

void cloneSources(string gitTag, string tgtDir)
{
    auto prefix = "https://github.com/D-Programming-Language/";
    auto fmt = "git clone --depth 1 -b "~gitTag~" "~prefix~"%1$s.git "~tgtDir~"/%1$s";
    foreach (proj; allProjects)
        run(fmt.format(proj));
}

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writeln("Expected <git-branch-or-tag> as only argument, e.g. v2.064.2.");
        return 1;
    }

    auto gitTag = args[1];
    auto workDir = mkdtemp();
    scope (success) if (workDir.exists) rmdirRecurse(workDir);
    // Cache huge downloads
    enum cacheDir = "cached_downloads";

    enum oldDMD = "dmd.2.065.b1.zip"; // TODO: determine from gitTag
    enum optlink = "optlink.zip";
    enum libCurl = "libcurl-7.34.0-WinSSL-zlib-x86-x64.zip";

    fetchFile("http://ftp.digitalmars.com/"~oldDMD, cacheDir~"/"~oldDMD);
    fetchFile("http://ftp.digitalmars.com/"~optlink, cacheDir~"/"~optlink);
    fetchFile("http://downloads.dlang.org/other/"~libCurl, cacheDir~"/"~libCurl);

    // Get previous dmd release
    extractZip(cacheDir~"/"~oldDMD, workDir~"/old-dmd");
    // Get latest optlink
    remove(workDir~"/old-dmd/dmd2/windows/bin/link.exe");
    extractZip(cacheDir~"/"~optlink, workDir~"/old-dmd/dmd2/windows/bin");
    // Get libcurl for windows
    extractZip(cacheDir~"/"~libCurl, workDir~"/old-dmd");

    // Get missing FreeBSD dmd.conf, this is a bug in 2.065.0-b1 and should be fixed in newer releases
    fetchFile(
        "https://raw.github.com/D-Programming-Language/dmd/"~gitTag~"/ini/freebsd/bin32/dmd.conf",
        buildPath(workDir, "old-dmd/dmd2/freebsd/bin32/dmd.conf"));

    fetchFile(
        "https://raw.github.com/D-Programming-Language/dmd/"~gitTag~"/ini/freebsd/bin64/dmd.conf",
        buildPath(workDir, "old-dmd/dmd2/freebsd/bin64/dmd.conf"));

    cloneSources(gitTag, workDir~"/clones");

    foreach (i, box; boxes)
    {
        immutable combine = i == boxes.length - 1;

        // skip a box if we already have its zip files
        if (("dmd."~gitTag~"."~box.platform~".zip").exists &&
            (!combine || ("dmd."~gitTag~".zip").exists))
            continue;

        box.up();
        scope (success) box.destroy();
        scope (failure) box.halt();

        box.scp(workDir~"/old-dmd", "default:");
        copyExtraBinaries(workDir, box);
        // copy create_dmd_release.d and dependencies
        box.scp("create_dmd_release.d common.d", "default:");
        box.scp(workDir~"/clones", "default:");

        // copy all zips into the last box to combine them
        if (combine)
        {
            foreach (b; boxes[0 .. $ - 1])
            {
                auto zip = "dmd."~gitTag~"."~b.platform~".zip";
                box.scp(zip, "default:"~zip);
            }
        }

        runBuild(box, gitTag, combine);
    }
    return 0;
}
