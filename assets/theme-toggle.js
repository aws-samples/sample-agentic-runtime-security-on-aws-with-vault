(function () {
  // HashiCorp logo — fixed to browser window top-left, above all slide content
  var logo = document.createElement('img');
  logo.src = 'assets/logo_horizontal.png';
  logo.style.cssText = 'position:fixed;top:12px;left:12px;z-index:200;width:160px;height:auto;pointer-events:none;opacity:0.9';
  document.body.appendChild(logo);

  // Branded gradient overlays — visible only on first and last slides
  var rightGradient = document.createElement('img');
  rightGradient.src = logo.src.replace('logo_horizontal.png', 'brand_right_gradient.png');
  rightGradient.style.cssText = 'position:fixed;top:0;right:0;height:100vh;width:auto;z-index:50;pointer-events:none;display:none';
  document.body.appendChild(rightGradient);

  var leftGradient = document.createElement('img');
  leftGradient.src = logo.src.replace('logo_horizontal.png', 'brand_left_gradient.png');
  leftGradient.style.cssText = 'position:fixed;bottom:0;left:0;height:100vh;width:auto;z-index:50;pointer-events:none;display:none';
  document.body.appendChild(leftGradient);

  function updateGradients() {
    if (typeof Reveal === 'undefined') return;
    var indices = Reveal.getIndices();
    var totalSlides = Reveal.getTotalSlides();
    var isFirstOrLast = (indices.h === 0 || indices.h === totalSlides - 1);
    rightGradient.style.display = isFirstOrLast ? 'block' : 'none';
    leftGradient.style.display = isFirstOrLast ? 'block' : 'none';
  }

  // Reveal may not exist yet — poll until ready, then attach events
  var pollInterval = setInterval(function () {
    if (typeof Reveal !== 'undefined' && Reveal.isReady()) {
      clearInterval(pollInterval);
      updateGradients();
      Reveal.on('slidechanged', updateGradients);
    }
  }, 100);

})();
