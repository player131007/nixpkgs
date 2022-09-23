{ lib
, buildPythonPackage
, fetchPypi
, pytestCheckHook
}:

buildPythonPackage rec {
  pname = "cronsim";
  version = "2.2";

  src = fetchPypi {
    inherit pname version;
    sha256 = "sha256-LMMZni8Cipo10mxAQbRadWpPvum76JQuzlrLvFvTt5o=";
  };

  checkInputs = [
    pytestCheckHook
  ];

  pythonImportsCheck = [ "cronsim" ];

  meta = with lib; {
    description = "Cron expression parser and evaluator";
    homepage = "https://github.com/cuu508/cronsim";
    license = licenses.bsd3;
    maintainers = with maintainers; [ phaer ];
  };
}
