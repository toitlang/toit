REM This script has been saved with 874 (Thai) encoding.
REM It tests that the Toit tools can handle non-UTF8 filenames.
chcp 874
mkdir �ʡ��ͻ
echo main: print "hello" > �ʡ��ͻ\main.toit
build\host\sdk\bin\toit.exe �ʡ��ͻ\main.toit
REM We need to reset the code page, as calling a program with a Unicode manifest changes
REM the active code page for the CMD script.
chcp 874
build\host\sdk\bin\toit.exe �ʡ��ͻ\main.toit > output.txt
chcp 874
build\host\sdk\bin\toit.exe compile --snapshot -o output.snapshot �ʡ��ͻ\main.toit
chcp 874
build\host\sdk\bin\toit.exe tool snapshot-to-image -o output.image --format=binary -m32 output.snapshot
