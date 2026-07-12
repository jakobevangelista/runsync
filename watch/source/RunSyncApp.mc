import Toybox.Application;
import Toybox.WatchUi;

class RunSyncApp extends Application.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() {
        return [new RunSyncField()];
    }
}
