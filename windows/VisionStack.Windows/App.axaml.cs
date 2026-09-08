using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using VisionStack.Windows.Services;
using VisionStack.Windows.ViewModels;
using VisionStack.Windows.Views;

namespace VisionStack.Windows;

public sealed partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            string dataRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "VisionStack");
            IProviderCredentialStore credentialStore = OperatingSystem.IsWindows()
                ? new DpapiProviderCredentialStore(Path.Combine(dataRoot, "credentials"))
                : new VolatileProviderCredentialStore();
            var viewModel = new MainWindowViewModel(dataRoot, credentialStore);
            desktop.MainWindow = new MainWindow
            {
                DataContext = viewModel
            };
            _ = viewModel.InitializeAsync();
        }

        base.OnFrameworkInitializationCompleted();
    }
}
