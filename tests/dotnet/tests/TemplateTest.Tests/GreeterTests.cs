namespace TemplateTest.Tests;

public class GreeterTests
{
    [Theory]
    [InlineData("Andy", "Hello, Andy!")]
    [InlineData("  Andy ", "Hello, Andy!")]
    [InlineData("", "Hello, world!")]
    public void Greet_FormatsName(string name, string expected) =>
        Assert.Equal(expected, Greeter.Greet(name));
}
