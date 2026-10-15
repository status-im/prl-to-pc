import std/options, os, strutils, regex, strformat

proc findAllStr(s: string, pattern: Regex2): seq[string] =
  for m in findAll(s, pattern):
    result.add s[m.boundaries]

type
  QtModule = object
    name*: string  # Full name including version and architecture
    description*: string
    version*: string
    requires*: seq[string]
    libName*: string
    libs*: string
    cflags*: string
    isStatic*: bool # Flag to indicate if the library is static
    isIOS*: bool    # Flag to indicate if the library is for iOS
    libPath*: string # Full path to the library file

proc getQtVersion(prlPath: string): string =
  ## Get Qt version from the .prl file name or content
  result = "6.0.0"  # Default version if not found
  let fileName = prlPath.splitPath().tail
  let versionMatch = findAllStr(fileName, re2"\d+\.\d+\.\d+")
  if versionMatch.len > 0:
    result = versionMatch[0]
  else:
    # Try to find version in parent directory names
    for parent in prlPath.parentDirs():
      let dirVersionMatch = findAllStr(parent.splitPath().tail, re2"\d+\.\d+\.\d+")
      if dirVersionMatch.len > 0:
        result = dirVersionMatch[0]
        break

proc isStaticLibrary(content: string): bool =
  ## Check if the .prl file represents a static library
  for line in content.splitLines():
    if line.startsWith("QMAKE_PRL_CONFIG") and (line.contains("static") or line.contains("staticlib")):
      return true
  return false

proc isIOSLibrary(filePath: string): bool =
  ## Check if the library is for iOS platform
  return filePath.contains("/ios/") or filePath.contains("_ios")

proc parseFrameworkName(filePath: string): string =
  ## Extract framework name from path for iOS libraries
  let parts = filePath.split("/")
  for i in 0..<parts.len:
    if parts[i].endsWith(".framework") and i > 0:
      return parts[i].split(".")[0]
  return ""

proc cleanFrameworkReferences(libs: string): string =
  ## Clean framework references like -framework $1
  result = libs
  # Replace framework references like "-framework $1" with proper framework names
  result = result.replace(re2"-framework\s+\$\d+", "")
  # Remove any remaining framework references with no valid name
  result = result.replace(re2"-framework\s+\$\[\w+\]", "")
  # Clean up any duplicate spaces
  result = result.replace(re2"\s+", " ").strip()
  return result

proc cleanInstallPathReferences(libs: string): string =
  ## Replace Qt install path references
  result = libs
  # Replace QT_INSTALL_LIBS references
  # Plain (literal) string replaces: the patterns are literal, and the ${...}
  # replacements must NOT go through nim-regex (it treats $ as a capture ref).
  result = result.replace("$$[QT_INSTALL_LIBS]", "${libdir}")
  result = result.replace("$$[QT_INSTALL_PREFIX]", "${prefix}")
  # Replace QT_INSTALL_PLUGINS references
  result = result.replace("$$[QT_INSTALL_PLUGINS]", "${prefix}/plugins")
  # Replace QT_INSTALL_QML references
  result = result.replace("$$[QT_INSTALL_QML]", "${prefix}/qml")
  return result

proc isBundledLibrary(libName: string): bool =
  ## Check if a library is a bundled library
  return libName.contains("Bundled") or libName.startsWith("Qt6Bundled")

proc extractBundledLibrary(part: string): string =
  ## Extract bundled library name from a library reference
  # Examples: libQt6BundledPcre2.a -> Qt6BundledPcre2
  let fileName = part.splitPath().tail
  if fileName.startsWith("lib") and fileName.endsWith(".a"):
    result = fileName.replace("lib", "").replace(".a", "")
  else:
    result = fileName.replace(".a", "")
  return result

proc getLibraryDir(prlFilePath: string): string =
  ## Get the directory where the library is actually located
  var dirPath = prlFilePath.splitPath().head
  # Handle framework directory structure (the .prl is typically in Resources)
  if dirPath.contains("/Resources"):
    dirPath = dirPath.splitPath().head  # Go up one level to the framework directory
  return dirPath

proc processFullPaths(libs: string, prefix: string): string =
  ## Process full paths to libraries to use -L/-l combination
  var result = libs
  let matches = findAllStr(libs, re2"\$\{libdir\}/lib[^/\s]+\.a")
  for match in matches:
    let libName = match.splitPath().tail.replace("lib", "").replace(".a", "")
    result = result.replace(match, "-l" & libName)
  
  return result

proc getDependencies(prlPath: string, content: string): seq[string] =
  ## Get Qt dependencies from the .prl file
  result = @[]
  
  for line in content.splitLines():
    if line.startsWith("QMAKE_PRL_LIBS_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        let depsStr = parts[1].strip()
        for part in depsStr.split(";"):
          # Check for Qt library dependencies in different formats
          if part.contains("Qt") or part.contains("qt"):
            var libName = ""
            
            # Handle frameworks
            if part.contains(".framework"):
              for fwPart in part.split("/"):
                if fwPart.contains(".framework"):
                  libName = fwPart.split(".")[0]
                  break
            # Handle bundled static libraries
            elif part.contains("libQt") and part.contains(".a"):
              libName = extractBundledLibrary(part)
            # Handle dynamic libraries. Produce the canonical package name that
            # matches the generated .pc filename (moduleInfo.name), i.e. strip
            # only the leading "lib" and the library extension while KEEPING the
            # Qt version and any arch suffix: libQt6Core_arm64-v8a.so ->
            # Qt6Core_arm64-v8a. (The previous "^lib(Qt\d*)? -> Qt" dropped the
            # version and never stripped ".so", yielding unresolvable
            # "QtCore_arm64-v8a.so" Requires entries.)
            elif part.contains("libQt"):
              let fileName = part.splitPath().tail
              libName = fileName.replace(re2"^lib", "")
                         .replace(re2"\.(a|so|dylib)(\.\d+)*$", "")
                         .replace("_debug", "")
            
            if libName.len > 0 and not result.contains(libName) and
               (libName.startsWith("Qt") or libName.startsWith("qt")):
              # Skip bundled libraries from Requires (they should only be in Libs)
              if not isBundledLibrary(libName):
                # Check if it's already added
                var alreadyAdded = false
                for dep in result:
                  if dep.toLower() == libName.toLower():
                    alreadyAdded = true
                    break
                
                if not alreadyAdded:
                  result.add(libName)

proc cleanLibraryName(name: string): string =
  # Strip Android ABI suffixes (one of these is present per single-arch kit),
  # the debug marker, and any framework extension, leaving the canonical Qt
  # module name (e.g. Qt6Core_arm64-v8a -> Qt6Core).
  result = name.replace("_arm64-v8a", "")
            .replace("_armeabi-v7a", "")
            .replace("_x86_64", "")
            .replace("_x86", "")
            .replace("_debug", "")
            .replace(".framework", "")

proc parseTargetDeps(cmakePath, moduleName: string): seq[string] =
  ## The required Qt dependencies declared in a <name>Dependencies.cmake.
  ## Parse ONLY the required-dependency declaration:
  ##   set(__qt_<Module>_target_deps "Qt6Core\;6.11.0;Qt6Network\;6.11.0")
  ## NOT the whole file (which contains example deps in comments — that produced a
  ## bogus Qt6Core->Qt6Gui edge and a Core<->Gui cycle that pkg-config-lite chokes
  ## on) and NOT the *optional*_target_deps line (optional deps can form cycles;
  ## the required graph is a DAG).
  if not fileExists(cmakePath):
    return @[]
  for line in readFile(cmakePath).splitLines():
    if "_target_deps \"" notin line or "optional" in line:
      continue
    let q1 = line.find('"')
    let q2 = line.rfind('"')
    if q1 < 0 or q2 <= q1:
      continue
    for dep in findAllStr(line[q1 + 1 ..< q2], re2"Qt6[A-Za-z0-9]+"):
      if dep != moduleName and dep notin result:
        result.add dep

proc getCMakeDeps(prlPath, moduleName: string): seq[string] =
  ## Read a Qt module's real dependencies from its <name>Dependencies.cmake (Qt
  ## ships these next to the libs, e.g. lib/cmake/Qt6Qml/Qt6QmlDependencies.cmake).
  ## Windows .prl files carry no dependency info, so without this the generated
  ## .pc files have no `Requires:` and pkg-config can't resolve transitive include
  ## dirs — e.g. compiling the Qt6Qml glue, which #includes <QObject> (a QtCore
  ## header), fails because -I.../include/QtCore (from Qt6Core's cflags) is missing.
  ## Only emit deps that have a sibling .prl (so a .pc is generated for them too);
  ## otherwise a `Requires:` entry would reference a package pkg-config can't find.
  let libDir = prlPath.splitPath().head
  let cmakePath = libDir / "cmake" / moduleName / (moduleName & "Dependencies.cmake")
  for dep in parseTargetDeps(cmakePath, moduleName):
    if fileExists(libDir / (dep & ".prl")):
      result.add dep

proc getIOSCMakeDeps(frameworkPath, moduleName: string): Option[seq[string]] =
  ## iOS variant of getCMakeDeps: modules are frameworks (lib/QtGui.framework)
  ## or static libs (lib/libQt6Foo.prl), so a dep gets a .pc when either exists.
  ## None when the module has no Dependencies.cmake.
  let libDir = frameworkPath.splitPath().head
  let cmakePath = libDir / "cmake" / moduleName / (moduleName & "Dependencies.cmake")
  if not fileExists(cmakePath):
    return none(seq[string])
  var deps: seq[string]
  for dep in parseTargetDeps(cmakePath, moduleName):
    if dirExists(libDir / ("Qt" & dep.substr(3) & ".framework")) or
       fileExists(libDir / ("lib" & dep & ".prl")):
      deps.add dep
  some(deps)

proc getFrameworkLibsString(module: QtModule): string =
  ## Generate framework Libs string including all dependencies
  var result = "-F${libdir} -framework " & module.libName
  
  # Add all required framework dependencies to the libs field
  for req in module.requires:
    if req.startsWith("Qt6") and req != "Qt6":
      # Convert Qt6ModuleName to the actual framework name (QtModuleName)
      let frameworkName = req.replace("Qt6", "Qt")
      result &= " -framework " & frameworkName
  
  return result

proc parseFramework*(frameworkPath: string): QtModule =
  ## Parse a Qt framework and extract module information
  var moduleInfo = QtModule()
  
  # Extract framework name from path
  let frameworkName = parseFrameworkName(frameworkPath)
  if frameworkName.len == 0:
    return moduleInfo
  
  # Store the framework path
  moduleInfo.libPath = frameworkPath
  
  # Set up the module info
  moduleInfo.isStatic = true  # iOS frameworks are static
  moduleInfo.isIOS = isIOSLibrary(frameworkPath)
  
  # Determine module name with proper Qt6 prefix
  if frameworkName.startsWith("Qt") and not frameworkName.startsWith("Qt6"):
    moduleInfo.name = "Qt6" & frameworkName.substr(2)
  else:
    moduleInfo.name = frameworkName
    
  moduleInfo.libName = frameworkName
  moduleInfo.description = moduleInfo.name & " module"
  
  # Try to extract version from the Qt installation path
  var version = "6.0.0"  # Default version
  for parent in frameworkPath.parentDirs():
    let versionMatch = findAllStr(parent.splitPath().tail, re2"\d+\.\d+\.\d+")
    if versionMatch.len > 0:
      version = versionMatch[0]
      break
  moduleInfo.version = version
  
  # Look for dependencies in CMake files
  var baseName = ""
  if moduleInfo.name.startsWith("Qt6"):
    baseName = moduleInfo.name.substr(3)  # Remove "Qt6" prefix
  else:
    baseName = moduleInfo.name
  
  # Requires: from the module's Dependencies.cmake, as Qt's own .pc lists them
  # (e.g. Multimedia -> Core Gui Concurrent Network). Frameworks Qt ships no
  # such file for (FFmpeg's) get none.
  moduleInfo.requires = getIOSCMakeDeps(frameworkPath, moduleInfo.name).get(@[])
  
  # Set up libs flags for linking - framework needs to be specified with all dependencies
  moduleInfo.libs = getFrameworkLibsString(moduleInfo)
  
  # Set up CFLAGS - For frameworks, we need to point to Headers directory
  var defineModuleName = baseName
  if defineModuleName.toLower().startsWith("qt"):
    defineModuleName = defineModuleName.substr(2)
  
  # For frameworks, we point directly to the Headers directory inside the framework
  # Also expose the flat include/ dir: some iOS modules (e.g. QtQmlIntegration,
  # pulled in by QtQml's qqmlregistration.h) ship headers there rather than in a
  # framework, and `<QtQmlIntegration/qqmlintegration.h>` only resolves via -I.
  moduleInfo.cflags = "-F${libdir} -I${includedir} -I${libdir}/" & frameworkName & ".framework/Headers -DQT_" & defineModuleName.toUpper() & "_LIB"
  
  return moduleInfo

proc parsePrlFile*(filePath: string): QtModule =
  var moduleInfo = QtModule()
  let content = readFile(filePath)
  
  # Check if it's a static library and/or iOS library
  moduleInfo.isStatic = isStaticLibrary(content)
  moduleInfo.isIOS = isIOSLibrary(filePath)
  
  # Store the path to the library file
  moduleInfo.libPath = getLibraryDir(filePath)
  
  # For iOS framework, get the framework name directly from the path
  let frameworkName = parseFrameworkName(filePath)
  
  for line in content.splitLines():
    if line.startsWith("QMAKE_PRL_BUILD_DIR"):
      continue
      
    if line.startsWith("QMAKE_PRL_TARGET"):
      let parts = line.split("=")
      if parts.len > 1:
        var libName = parts[1].strip()
        if moduleInfo.isIOS and frameworkName.len > 0:
          # For iOS frameworks, use the framework name
          moduleInfo.libName = frameworkName
          moduleInfo.name = frameworkName
        else:
          # For regular libraries
          moduleInfo.libName = libName

          # Derive the canonical pkg-config name from QMAKE_PRL_TARGET, whose
          # form is platform-dependent: libQt6Core.so / libQt6Core.a (Unix),
          # Qt6Core.lib (Windows import lib) or Qt6Core.dll. Strip a leading
          # "lib" prefix and the platform library extension only. A blanket
          # replace("lib","") would also eat the "lib" inside ".lib", yielding
          # "Qt6Core." — which no longer matches `pkg-config Qt6Core`.
          moduleInfo.name = libName
            .replace(re2"^lib", "")
            .replace(re2"\.(a|so|dylib|lib|dll)(\.\d+)*$", "")
        
        moduleInfo.description = moduleInfo.name & " module"
        
    elif line.startsWith("QMAKE_PRL_VERSION"):
      let parts = line.split("=")
      if parts.len > 1:
        moduleInfo.version = parts[1].strip()

    elif line.startsWith("QMAKE_PRL_LIBS_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        moduleInfo.requires = getDependencies(filePath, content)

    elif line.startsWith("QMAKE_PRL_LIBS") and not line.contains("_FOR_CMAKE"):
      let parts = line.split("=")
      if parts.len > 1:
        var libs = parts[1].strip()
        
        # Clean framework references like -framework $1
        libs = cleanFrameworkReferences(libs)
        
        # Replace QT_INSTALL_LIBS and other path references
        libs = cleanInstallPathReferences(libs)
        
        # Replace semicolons with spaces
        libs = libs.replace(";", " ")
        
        if moduleInfo.isStatic:
          # For static libraries, we need to handle differently
          if moduleInfo.isIOS and frameworkName.len > 0:
            # For iOS static frameworks, use framework linking with dependencies
            moduleInfo.libs = getFrameworkLibsString(moduleInfo) & " " & libs
          else:
            # For regular static libraries. Qt module libs always live in the
            # kit's lib/ dir, which the generated .pc defines as ${libdir}
            # (= ${prefix}/lib) — use it so the path is prefix-relocatable.
            moduleInfo.libs = "-L${libdir} -l" & moduleInfo.name & " " & libs
        else:
          # For dynamic libraries: normalise each token. A blanket
          # replace("lib","-l") corrupts ${libdir} and full-path references
          # (e.g. ${libdir}/libQt6OpenGL_arm64-v8a.so -> /-lQt6OpenGL...), so
          # tokenise instead: convert any full-path library reference to
          # -l<name> (keeping version/arch suffix) and pass through existing
          # -l/-L/system flags unchanged.
          var cleanedTokens: seq[string] = @[]
          for tok in libs.splitWhitespace():
            if tok.len == 0:
              continue
            let fname = tok.splitPath().tail
            if fname.startsWith("lib") and (tok.contains("/") or tok.contains("$")):
              let name = fname.replace(re2"^lib", "")
                              .replace(re2"\.(a|so|dylib)(\.\d+)*$", "")
              cleanedTokens.add("-l" & name)
            else:
              cleanedTokens.add(tok)
          libs = cleanedTokens.join(" ")
          # Qt module libs live in the kit's lib/ dir, exposed by the generated
          # .pc as ${libdir} (= ${prefix}/lib) — use it so the path stays
          # prefix-relocatable instead of being hard-coded to one kit location.
          moduleInfo.libs = "-L${libdir} -l" & moduleInfo.name & " " & libs
        
        # Process any full paths to use -L/-l combination
        moduleInfo.libs = processFullPaths(moduleInfo.libs, "${prefix}")
  
  # If no libs were set yet but we have a framework, set them now with dependencies
  if moduleInfo.libs.len == 0 and moduleInfo.isIOS and frameworkName.len > 0:
    moduleInfo.libs = getFrameworkLibsString(moduleInfo)

  # Ensure the module's own library is linked. Windows shared modules (e.g.
  # Qt6Core.prl) carry only TARGET/CONFIG/VERSION and no QMAKE_PRL_LIBS line, so
  # the `-L${libdir} -l<name>` above is never emitted and Libs: comes out empty —
  # making `pkg-config --libs Qt6Core` return nothing. Prepend it here when the
  # module's own -l flag isn't already present. (iOS frameworks link differently,
  # handled above.)
  if not moduleInfo.isIOS and moduleInfo.name.len > 0 and
     ("-l" & moduleInfo.name) notin moduleInfo.libs:
    let ownLib = "-L${libdir} -l" & moduleInfo.name
    moduleInfo.libs =
      if moduleInfo.libs.len > 0: ownLib & " " & moduleInfo.libs
      else: ownLib

  # Populate Requires: from the module's Dependencies.cmake when the .prl itself
  # carried none (always the case on Windows). This gives pkg-config the transitive
  # cflags (include dirs) and libs of dependency modules.
  if not moduleInfo.isIOS and moduleInfo.requires.len == 0 and moduleInfo.name.len > 0:
    moduleInfo.requires = getCMakeDeps(filePath, moduleInfo.name)

  # Generate appropriate CFLAGS.
  # Work from the arch-stripped canonical name (Qt6Core, not Qt6Core_arm64-v8a)
  # so the header subdir and feature define are correct. The Qt header subdir is
  # "Qt" + the part after the "Qt<ver>" prefix (Qt6Core -> Core -> QtCore); the
  # feature define is QT_<MODULE>_LIB. `^Qt\d*` strips both the Android form
  # (Qt6Core) and the iOS framework form (QtCore, no version digits).
  let cleanName = cleanLibraryName(moduleInfo.name)
  let moduleSuffix = cleanName.replace(re2"^Qt\d*", "")
  let includeSubdir = "Qt" & moduleSuffix
  let defineModuleName = moduleSuffix

  if moduleInfo.isIOS:
    # For iOS frameworks, point directly to the Headers directory
    # See parseFramework: also add the flat include/ dir for header-only iOS
    # modules (e.g. QtQmlIntegration) that aren't packaged as frameworks.
    moduleInfo.cflags = "-F${libdir} -I${includedir} -I${libdir}/" & moduleInfo.libName & ".framework/Headers -DQT_" & defineModuleName.toUpper() & "_LIB"
  else:
    moduleInfo.cflags = "-I${includedir} -I${includedir}/" & includeSubdir & " -DQT_" & defineModuleName.toUpper() & "_LIB"
  
  return moduleInfo

proc generatePcFile(module: QtModule, outputDir: string, prefix: string, hostBins: string) =
  # pkg-config .pc files must use forward slashes for path variables on ALL
  # platforms: pkg-config treats backslash as an escape and silently drops it,
  # so ${prefix}\include would expand to "<prefix>include". Don't use the host's
  # DirSep here (it's "\" on Windows).
  let host_bins = if hostBins.len > 0: hostBins else: "${prefix}/bin"
  ## Generate a .pc file for a Qt module
  let content = fmt"""prefix={prefix}
exec_prefix=${{prefix}}
bindir=${{prefix}}/bin
libexecdir=${{prefix}}/libexec
libdir=${{prefix}}/lib
includedir=${{prefix}}/include
host_bins={host_bins}

Name: {module.name}
Description: {module.description}
Version: {module.version}
Libs: {module.libs}
Cflags: {module.cflags}"""
  
  let finalContent = if module.requires.len > 0:
    content & "\nRequires: " & module.requires.join(" ")
  else:
    content
  
  # Use the module name without additional Qt prefix
  let outputPath = joinPath(outputDir, module.name & ".pc")
  echo "Writing to: ", outputPath
  writeFile(outputPath, finalContent & "\n")

proc processDirectory(dir: string, outputDir: string, prefix: string, hostBins: string) =
  ## Recursively process a directory for .prl files
  echo "Processing directory: ", dir
  for kind, path in walkDir(dir):
    if kind == pcFile and path.endsWith(".prl"):
      echo "Found .prl file: ", path
      let module = parsePrlFile(path)
      generatePcFile(module, outputDir, prefix, hostBins)
    elif kind == pcDir:
      processDirectory(path, outputDir, prefix, hostBins)

proc scanForFrameworks(dir: string, outputDir: string, prefix: string, hostBins: string) =
  ## Recursively scan for frameworks and generate .pc files for them
  echo "Scanning for frameworks in: ", dir
  for kind, path in walkDir(dir):
    if kind == pcDir and path.endsWith(".framework"):
      echo "Found framework: ", path
      let module = parseFramework(path)
      if module.name.len > 0:  # Only process if we have a valid module
        generatePcFile(module, outputDir, prefix, hostBins)
    elif kind == pcDir:
      scanForFrameworks(path, outputDir, prefix, hostBins)

proc createBaseQtPcFile(outputDir: string, prefix: string, hostBins: string) =
  ## Create a base Qt6.pc file that other Qt modules can depend on
  # pkg-config .pc files must use forward slashes for path variables on ALL
  # platforms: pkg-config treats backslash as an escape and silently drops it,
  # so ${prefix}\include would expand to "<prefix>include". Don't use the host's
  # DirSep here (it's "\" on Windows).
  let host_bins = if hostBins.len > 0: hostBins else: "${prefix}/bin"
  let content = fmt"""prefix={prefix}
exec_prefix=${{prefix}}
bindir=${{prefix}}/bin
libexecdir=${{prefix}}/libexec
libdir=${{prefix}}/lib
includedir=${{prefix}}/include
host_bins={host_bins}

Name: Qt6
Description: Qt6 base module
Version: 6.8.3
Libs: 
Cflags:
"""
  
  let outputPath = joinPath(outputDir, "Qt6.pc")
  echo "Writing base Qt6.pc file to: ", outputPath
  writeFile(outputPath, content)

proc convertPrlToPc*(inputDir, outputDir, prefix, hostBins: string) =
  ## Convert Qt .prl files to pkg-config files
  ## inputDir: Directory containing .prl files
  ## outputDir: Directory where .pc files will be generated
  ## prefix: Installation prefix path for the libraries
  createDir(outputDir)
  
  # Create a base Qt6.pc file first
  createBaseQtPcFile(outputDir, prefix, hostBins)
  
  echo "Scanning directory for .prl files: ", inputDir
  processDirectory(inputDir, outputDir, prefix, hostBins)
  
  echo "Scanning directory for frameworks: ", inputDir
  scanForFrameworks(inputDir, outputDir, prefix, hostBins)

proc generateBundled*(qtPath, outRoot: string) =
  ## Generate a committed, relocatable pkg-config tree that mirrors Qt's own
  ## on-disk layout:  <outRoot>/<version>/<kit>/lib/pkgconfig/*.pc
  ##
  ## `qtPath` is the Qt kit dir or its lib/ subdir (the dir holding the .prl
  ## files), e.g. C:/Qt/6.11.0/msvc2022_64 or .../msvc2022_64/lib. The Qt
  ## version and kit are derived from the path (<...>/<version>/<kit>[/lib]).
  ##
  ## A placeholder prefix (@@QT_PREFIX@@) is baked because consumers resolve
  ## ${prefix} from the .pc file's location via `pkg-config --define-prefix`
  ## once the files sit under a real <kit>/lib/pkgconfig — so the literal value
  ## is never used at build time. host_bins defaults to ${prefix}/bin (so the
  ## tree stays prefix-relocatable).
  var libDir = qtPath
  while libDir.len > 0 and libDir[^1] in {'/', '\\'}:
    libDir.setLen(libDir.len - 1)
  # Accept either the kit dir or its lib/ subdir.
  if cmpIgnoreCase(lastPathPart(libDir), "lib") != 0 and dirExists(libDir / "lib"):
    libDir = libDir / "lib"
  let prefixDir = parentDir(libDir)               # <...>/<version>/<kit>
  let kit = lastPathPart(prefixDir)               # e.g. msvc2022_64
  let version = lastPathPart(parentDir(prefixDir)) # e.g. 6.11.0
  if version.len == 0 or kit.len == 0:
    quit("prl_to_pc generate: could not derive <version>/<kit> from path: " & qtPath, 1)

  let outDir = outRoot / version / kit / "lib" / "pkgconfig"
  echo "Qt version: ", version, "  kit: ", kit
  echo "Input  (libs): ", libDir
  echo "Output (.pc):  ", outDir
  removeDir(outDir)   # clean regenerate (idempotent)
  # Placeholder prefix + empty hostBins (-> ${prefix}/bin) keep the tree
  # machine-independent; --define-prefix resolves the real prefix on consume.
  convertPrlToPc(libDir, outDir, "@@QT_PREFIX@@", "")

when isMainModule:
  # `generate` mode: bundles all the layout/prefix logic — derives the Qt
  # version+kit from the libs path and writes <outRoot>/<version>/<kit>/lib/pkgconfig.
  if paramCount() >= 1 and paramStr(1) == "generate":
    if paramCount() < 2:
      echo "Usage: prl_to_pc generate <qt_lib_dir> [out_root]"
      quit(1)
    let qtPath = paramStr(2)
    let outRoot = if paramCount() >= 3: paramStr(3) else: getCurrentDir()
    generateBundled(qtPath, outRoot)
    quit(0)

  if paramCount() < 3:
    echo "Usage: prl_to_pc <input_dir> <output_dir> <prefix>"
    echo "   or: prl_to_pc convert <input_dir> <output_dir> <prefix>"
    echo "   or: prl_to_pc generate <qt_lib_dir> [out_root]"
    quit(1)
  echo "paramCount: ", paramCount()
  var inputDir, outputDir, prefix, hostBins: string

  if paramStr(1) == "convert":
    if paramCount() < 4:
      echo "Usage: prl_to_pc convert <input_dir> <output_dir> <prefix>"
      quit(1)
    inputDir = paramStr(2)
    outputDir = paramStr(3)
    prefix = paramStr(4)
    if paramCount() > 4:
      hostBins = paramStr(5)
  else:
    inputDir = paramStr(1)
    outputDir = paramStr(2)
    prefix = paramStr(3)
    if paramCount() > 3:
      hostBins = paramStr(4)

  echo "inputDir: ", inputDir
  echo "outputDir: ", outputDir
  echo "prefix: ", prefix
  echo "hostBins: ", hostBins
  
  convertPrlToPc(inputDir, outputDir, prefix, hostBins) 