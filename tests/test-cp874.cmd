REM This script has been saved with 874 (Thai) encoding.
REM It tests that the Toit tools can handle non-UTF8 filenames.
chcp 874
mkdir �ʡ��ͻ
echo main: print "hello" > �ʡ��ͻ\main.toit
build\host\sdk\bin\toit.exe �ʡ��ͻ\main.toit
build\host\sdk\bin\toit.exe �ʡ��ͻ\main.toit > output.txt
build\host\sdk\bin\toit.exe compile --snapshot -o output.snapshot �ʡ��ͻ\main.toit
build\host\sdk\bin\toit.exe tool snapshot-to-image -o output.image --format=binary -m32 output.snapshot
