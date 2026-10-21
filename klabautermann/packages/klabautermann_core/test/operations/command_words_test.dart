import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

void main() {
  group('splitCommandWords (CTX-08)', () {
    test('splits at blanks, any number of them', () {
      expect(splitCommandWords('  ls   -la\t/tmp \n'), ['ls', '-la', '/tmp']);
    });

    test('single quotes keep their text as is', () {
      expect(splitCommandWords(r"echo 'a  b' '$HOME' 'x\y'"), [
        'echo',
        'a  b',
        r'$HOME',
        r'x\y',
      ]);
    });

    test('double quotes escape only the characters a shell does', () {
      expect(splitCommandWords(r'echo "a \"b\" \\ \$ \` \n"'), [
        'echo',
        r'a "b" \ $ ` \n',
      ]);
    });

    test('a backslash outside quotes takes the next character', () {
      expect(splitCommandWords(r'touch a\ b \"c'), ['touch', 'a b', '"c']);
    });

    test('quoted parts join the word around them, and an empty quote is a '
        'word', () {
      expect(splitCommandWords('''x="a b"'c' ""'''), ['x=a bc', '']);
    });

    test('nothing is expanded: no shell runs the words', () {
      expect(splitCommandWords(r'sh -c "echo $HOME | wc"'), [
        'sh',
        '-c',
        r'echo $HOME | wc',
      ]);
      expect(splitCommandWords('ls *; rm x'), ['ls', '*;', 'rm', 'x']);
    });

    test('an open quote or no words is no command', () {
      expect(splitCommandWords("echo 'open"), isNull);
      expect(splitCommandWords('echo "open'), isNull);
      expect(splitCommandWords(r'echo "a\"'), isNull);
      expect(splitCommandWords('   '), isNull);
      expect(splitCommandWords(''), isNull);
    });
  });
}
