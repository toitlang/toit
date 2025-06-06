REM This script has been saved with 874 (Thai) encoding.
REM It tests that the Toit tools can handle non-UTF8 filenames.
chcp 874
mkdir à´Ê¡ì·çÍ»
echo main: print "hello" > à´Ê¡ì·çÍ»\main.toit
build\host\sdk\bin\toit.exe à´Ê¡ì·çÍ»\main.toit > output.txt
build\host\sdk\bin\toit.exe compile --snapshot -o output.snapshot à´Ê¡ì·çÍ»\main.toit
build\host\sdk\bin\toit.exe tool snapshot-to-image -o output.image --format=binary -m32 output.snapshot
