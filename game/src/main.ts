import './styles.css';
import { startApp } from './app';

startApp().catch(err => {
  console.error(err);
  const msg = document.getElementById('loadMsg');
  if (msg) msg.textContent = 'Something went wrong while loading. Reload to try again.';
});
