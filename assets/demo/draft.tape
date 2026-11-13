# Records draft.gif: run vhs assets/demo/draft.tape in the root of the repository
Output assets/demo/draft.gif

Set Shell bash
Set FontSize 16
Set Width 1360
Set Height 310
Set Padding 20
Set Theme "GitHub Dark"
Set TypingSpeed 60ms

Hide
Type "source assets/demo/draft-setup.sh && clear"
Enter
Show

Type "./aurtomator.sh draft hello-bin"
Sleep 500ms
Enter
Wait+Screen /update available/
Sleep 4s

Hide
Type "cd / && teardown_test_env"
Enter
